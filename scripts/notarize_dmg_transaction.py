#!/usr/bin/env python3
"""Durable DMG continuation. Never resubmit an uncertain Apple transaction."""
from __future__ import annotations

import argparse
import ctypes
from dataclasses import asdict
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import select
import stat
import sys
import tempfile
import uuid

from dmg_contents import assert_app_matches_zip, assert_volume_inventory
import notarize_direct_transaction as notary
import notary_transaction_state as state
import release_input_snapshot as snapshot
import release_source_receipt as source
import release_transaction as transaction
import release_candidate_location as location

MAX_BYTES = 16 * 1024**3
STAGES = ("created", "qualified", "submit-intent", "submission-known",
          "accepted", "final-verified", "sidecar-committed", "dmg-committed", "complete")
POLICY_CLOSURE = tuple(sorted(set(source.RELEASE_SOURCE_CLOSURE) | {
    ("scripts/notarize_dmg_transaction.py", "dmg-transaction"),
    ("scripts/dmg_contents.py", "dmg-content-comparison"),
    ("scripts/release-direct-dmg.sh", "dmg-packaging"),
    ("scripts/verify-direct-notarized-dmg.sh", "dmg-verification"),
    ("scripts/export-direct-distribution.py", "notary-output-copy"),
}))


class DMGError(RuntimeError):
    pass


def canonical(path: Path) -> Path:
    """Reject aliases and symlink ancestors instead of silently normalizing them."""
    path = path.absolute()
    if path != path.resolve():
        raise DMGError("Transaction path must be canonical")
    return path


def encode_seal(seal):
    result = asdict(seal)
    result["path"] = str(seal.path)
    return result


def decode_seal(payload, path):
    if not isinstance(payload, dict) or payload.get("path") != str(path):
        raise DMGError("Artifact seal path is invalid")
    try:
        seal = transaction.FileSeal(**{**payload, "path": path})
    except (TypeError, ValueError) as error:
        raise DMGError("Artifact seal is invalid") from error
    if (not re.fullmatch(r"[0-9a-f]{64}", str(seal.sha256)) or
            any(type(getattr(seal, name)) is not int for name in
                ("size", "device", "inode", "mtime_ns", "ctime_ns", "uid", "mode"))):
        raise DMGError("Artifact seal is invalid")
    return seal


def read_receipt(path):
    seal = transaction.seal_regular_file(path, maximum_bytes=1024**2)
    if seal.mode != 0o400:
        raise DMGError("Receipt is not immutable")
    with path.open("rb") as stream:
        payload = json.load(stream, object_pairs_hook=reject_duplicates)
    transaction.assert_sealed(seal, maximum_bytes=1024**2)
    return payload, seal.sha256


def reject_duplicates(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise DMGError("Receipt contains duplicate keys")
        result[key] = value
    return result


class Receipts:
    """Write-once chained receipts; gaps and changed input bindings fail closed."""
    def __init__(self, root):
        self.root = canonical(root)
        state.ensure_private_directory(root)
        self.data = {}
        self.index = -1
        self.previous = None
        gap = False
        binding = None
        for index, stage in enumerate(STAGES):
            path = self.path(stage)
            if not os.path.lexists(path):
                gap = True
                continue
            if gap:
                raise DMGError("Receipt chain has a gap")
            payload, digest = read_receipt(path)
            if (not isinstance(payload, dict) or set(payload) !=
                    {"schema", "stage", "previous", "data"} or
                    payload["schema"] != 1 or payload["stage"] != stage or
                    payload["previous"] != self.previous or
                    not isinstance(payload["data"], dict)):
                raise DMGError("Receipt chain is invalid")
            data = payload["data"]
            if index == 0:
                binding = data
            elif any(data.get(k) != v for k, v in self.data.items()):
                raise DMGError("Receipt changed an earlier binding")
            self.data, self.index, self.previous = data, index, digest
        self.binding = binding

    def path(self, stage):
        return self.root / f"{STAGES.index(stage):02d}-{stage}.json"

    def reached(self, stage):
        return self.index >= STAGES.index(stage)

    def append(self, stage, **fields):
        if STAGES.index(stage) != self.index + 1:
            raise DMGError("Receipt transition is invalid")
        if set(fields) & set(self.data):
            raise DMGError("Receipt cannot replace an earlier binding")
        notary.write_private_json(self.path(stage), {
            "schema": 1, "stage": stage, "previous": self.previous,
            "data": {**self.data, **fields},
        })
        refreshed = Receipts(self.root)
        self.__dict__.update(refreshed.__dict__)


def checked(runner, command, project):
    result = runner(command, project)
    if result.returncode:
        # Native output can contain account details/private paths. Keep it private.
        raise DMGError("Required external DMG phase failed; transaction retained")
    return result.output


def verify_image_copy(seal, action):
    """Native image readers may write checksum/provenance xattrs.

    Run them on a disposable exact copy. The retained image keeps its full
    inode/ctime seal; the copy must retain identical bytes, mode and identity.
    Its ctime may change because hdiutil caches a checksum in an xattr.
    """
    def verify():
        with tempfile.TemporaryDirectory(prefix="verify-image-", dir=seal.path.parent.parent) as directory:
            image = Path(directory).resolve() / seal.path.name
            snapshot.snapshot_release_input(seal.path, image, maximum_bytes=MAX_BYTES)
            copied = transaction.seal_regular_file(image, maximum_bytes=MAX_BYTES)
            if copied.sha256 != seal.sha256:
                raise DMGError("Native image copy differs from retained bytes")
            transaction.write_checksum_sidecar(copied, image.with_name(image.name + ".sha256"))
            return observe_native_image_copy(copied, lambda: action(image))
    return transaction.observe_sealed_phase(seal, verify, maximum_bytes=MAX_BYTES)


def observe_native_image_copy(seal, action):
    """Reject transient writes; allow only observed native checksum/provenance metadata."""
    if not hasattr(select, "kqueue"):
        raise DMGError("Native image copy requires macOS vnode observation")
    transaction.assert_sealed(seal, maximum_bytes=MAX_BYTES)
    descriptor = os.open(seal.path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    queue = select.kqueue()
    unsafe = (select.KQ_NOTE_WRITE | select.KQ_NOTE_EXTEND | select.KQ_NOTE_LINK |
              select.KQ_NOTE_RENAME | select.KQ_NOTE_DELETE | select.KQ_NOTE_REVOKE)
    def attributes():
        return image_attributes(descriptor)
    try:
        before = attributes()
        queue.control([select.kevent(descriptor, filter=select.KQ_FILTER_VNODE,
            flags=select.KQ_EV_ADD | select.KQ_EV_CLEAR, fflags=unsafe | select.KQ_NOTE_ATTRIB)], 0, 0)
        error = None
        result = None
        try:
            result = action()
        except BaseException as caught:
            error = caught
        events = queue.control(None, 8, 0)
        after = transaction.seal_regular_file(seal.path, maximum_bytes=MAX_BYTES)
        named = seal.path.stat(follow_symlinks=False)
        opened = os.fstat(descriptor)
        after_attributes = attributes()
        events += queue.control(None, 8, 0)
        changed = {key for key in before.keys() | after_attributes.keys()
                   if before.get(key) != after_attributes.get(key)}
        if (any(event.fflags & unsafe for event in events) or
                any(getattr(seal, key) != getattr(after, key) for key in
                    ("sha256", "size", "device", "inode", "mtime_ns", "uid", "mode")) or
                named.st_nlink != 1 or opened.st_nlink != 1 or
                (opened.st_dev, opened.st_ino) != (seal.device, seal.inode) or
                changed - {"com.apple.diskimages.recentcksum", "com.apple.provenance"} or
                (after.ctime_ns != seal.ctime_ns and not changed)):
            raise DMGError("Native image verification changed its input or unapproved metadata") from error
        if error is not None:
            raise error
        return result
    finally:
        queue.close()
        os.close(descriptor)


def image_attributes(descriptor):
    """Bounded descriptor-based Darwin xattr reads; values never enter diagnostics."""
    libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
    libc.flistxattr.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int]
    libc.flistxattr.restype = ctypes.c_ssize_t
    libc.fgetxattr.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_void_p,
                             ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int]
    libc.fgetxattr.restype = ctypes.c_ssize_t
    size = libc.flistxattr(descriptor, None, 0, 0)
    if not 0 <= size <= 65536:
        raise DMGError("Native image attribute inventory refused")
    names = ctypes.create_string_buffer(size or 1)
    length = libc.flistxattr(descriptor, names, size, 0)
    if length != size:
        raise DMGError("Native image attributes changed during inventory")
    result = {}
    for name in names.raw[:length].split(b"\0"):
        if not name:
            continue
        value_size = libc.fgetxattr(descriptor, name, None, 0, 0, 0)
        if not 0 <= value_size <= 1024 * 1024:
            raise DMGError("Native image attribute size refused")
        value = ctypes.create_string_buffer(value_size or 1)
        if libc.fgetxattr(descriptor, name, value, value_size, 0, 0) != value_size:
            raise DMGError("Native image attribute changed during read")
        result[name.decode("utf-8", errors="strict")] = value.raw[:value_size]
    return result


def copy_notary_zip(archive, destination):
    """Export the known notary output without weakening general snapshot custody."""
    spec = importlib.util.spec_from_file_location("dmg_notary_export", Path(__file__).with_name("export-direct-distribution.py"))
    exporter = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(exporter)
    checksum = archive.with_name(archive.name + ".sha256")
    copied_checksum = destination.with_name(destination.name + ".sha256")
    checksum_record = exporter.copy_verified(checksum, copied_checksum, maximum_bytes=4096)
    match = re.fullmatch(r"([a-f0-9]{64})  " + re.escape(archive.name) + r"\n", copied_checksum.read_text())
    if not match:
        raise DMGError("Notary ZIP checksum format is invalid")
    archive_record = exporter.copy_verified(archive, destination, match[1], maximum_bytes=MAX_BYTES)
    return copied_checksum, archive_record, checksum_record, match[1]


def qualify_contents(project, dmg, archive, runner, manifest, channel):
    """Native signature/container checks and byte-for-byte qualified ZIP contents."""
    if dmg.stat().st_size < 50_000_000:
        raise DMGError("DMG is unexpectedly small")
    checked(runner, ["hdiutil", "verify", str(dmg)], project)
    checked(runner, ["codesign", "--verify", "--verbose=2", str(dmg)], project)
    signature = checked(runner, ["codesign", "--display", "--verbose=4", str(dmg)], project)
    # codesign writes display details to stderr; do not print them.
    if "Authority=Developer ID Application:" not in signature or "Timestamp=" not in signature:
        raise DMGError("DMG requires Developer ID and trusted timestamp")
    with tempfile.TemporaryDirectory(prefix="neantik-dmg-contents-") as temporary:
        mount = Path(temporary).resolve() / "mount"
        mount.mkdir(mode=0o700)
        try:
            checked(runner, ["hdiutil", "attach", "-readonly", "-nobrowse",
                            "-mountpoint", str(mount), str(dmg)], project)
            app = mount / "NeAntik.app"
            assert_volume_inventory(mount)
            checked(runner, ["codesign", "--verify", "--deep", "--strict", str(app)], project)
            if not (mount / "Applications").is_symlink() or os.readlink(mount / "Applications") != "/Applications":
                raise DMGError("Applications shortcut is invalid")
            assert_app_matches_zip(app, archive)
            checked(runner, [sys.executable, "-I", "-B",
                            str(project / "scripts/run-isolated-release-python.py"),
                            str(project / "scripts/direct-candidate-manifest.py"),
                            "verify", "--app", str(app), "--manifest", str(manifest),
                            "--release-channel", channel], project)
            # The image must use the app's actual certificate, not another signer.
            certificates = []
            for index, item in enumerate((dmg, app)):
                prefix = Path(temporary).resolve() / f"certificate-{index}"
                checked(runner, ["codesign", "--display", f"--extract-certificates={prefix}", str(item)], project)
                leaf = Path(str(prefix) + "0")
                with leaf.open("rb") as stream:
                    certificates.append(stream.read(1024 * 1024 + 1))
            if (not certificates[0] or len(certificates[0]) > 1024 * 1024 or
                    certificates[0] != certificates[1]):
                raise DMGError("DMG and app signing certificates differ")
        finally:
            # Even an attach returning an error can have mounted the image.
            if os.path.ismount(mount):
                checked(runner, ["hdiutil", "detach", str(mount)], project)


def native_runner(command, cwd):
    result = notary.default_runner(command, cwd)
    if command[:2] == ["codesign", "--display"]:
        return notary.CommandResult(result.returncode, result.output + result.stderr)
    return result


def run(root, project, destination, profile, *, runner=native_runner,
        capture=source.capture_release_source, qualify=qualify_contents,
        fault=lambda stage: None, progress=lambda stage: None):
    """Continue known ID only. submit-intent without ID needs manual reconciliation."""
    project, destination = canonical(project), canonical(destination)
    receipts = Receipts(root)
    data = receipts.data
    if not receipts.reached("created"):
        raise DMGError("Transaction has no created receipt")
    if data.get("project") != str(project) or data.get("destination") != str(destination) or data.get("profile") != profile:
        raise DMGError("Transaction invocation differs from its binding")
    current_source = capture(project, closure=POLICY_CLOSURE)
    if current_source.payload != data.get("source"):
        raise DMGError("Release source changed; resume refused")
    submitted = decode_seal(data["submitted"], root / "submitted" / destination.name)
    archive = decode_seal(data["archive"], root / "archive" / destination.with_suffix(".zip").name)
    archive_checksum = decode_seal(data["archiveChecksum"], archive.path.with_name(archive.path.name + ".sha256"))
    manifest = decode_seal(data["manifest"], root / "candidate" / "direct-candidate-manifest.json")
    transaction.assert_sealed(submitted, maximum_bytes=MAX_BYTES)
    transaction.assert_sealed(archive, maximum_bytes=MAX_BYTES)
    transaction.assert_sealed(archive_checksum, maximum_bytes=4096)
    transaction.assert_sealed(manifest, maximum_bytes=16 * 1024**2)
    transaction.assert_checksum_matches_archive(archive, archive_checksum)

    def immutable(action):
        result = transaction.observe_sealed_phase(manifest, lambda:
            transaction.observe_sealed_phase(archive_checksum, lambda:
                transaction.observe_sealed_phase(archive, lambda:
                    transaction.observe_sealed_phase(submitted, action, maximum_bytes=MAX_BYTES),
                    maximum_bytes=MAX_BYTES), maximum_bytes=4096), maximum_bytes=16 * 1024**2)
        source.assert_release_source_unchanged(current_source)
        return result

    def advance(stage, **fields):
        source.assert_release_source_unchanged(current_source)
        receipts.append(stage, **fields)
        progress(stage)
        fault(stage)

    def call(command):
        return checked(runner, command, project)

    if not receipts.reached("qualified"):
        progress("checking qualified ZIP")
        immutable(lambda: call([str(project / "scripts/verify-direct-notarized-archive.py"),
                              "--project-root", str(project), "--archive", str(archive.path)]))
        progress("checking signed image contents")
        immutable(lambda: verify_image_copy(submitted, lambda image:
            qualify(project, image, archive.path, runner, manifest.path, data["channel"])))
        advance("qualified")
    if not receipts.reached("submit-intent"):
        immutable(lambda: notary.preflight_notary_profile(project_root=project, notary_profile=profile, runner=runner))
        advance("submit-intent")
        output = immutable(lambda: call(["xcrun", "notarytool", "submit", str(submitted.path),
                                       "--keychain-profile", profile, "--output-format", "json"]))
        identifier = notary.parse_notary_submission(output)
        advance("submission-known", submissionID=identifier)
    elif not receipts.reached("submission-known"):
        raise DMGError("Apple submission outcome is uncertain; do not resubmit")
    identifier = receipts.data["submissionID"]
    if not isinstance(identifier, str) or str(uuid.UUID(identifier)) != identifier:
        raise DMGError("Retained Apple submission ID is invalid")
    if not receipts.reached("accepted"):
        output = immutable(lambda: call(["xcrun", "notarytool", "wait", identifier,
                                       "--keychain-profile", profile, "--output-format", "json"]))
        notary.parse_notary_result(output, expected_identifier=identifier)
        log_output = immutable(lambda: call(["xcrun", "notarytool", "log", identifier,
                                            "--keychain-profile", profile]))
        apple_log = validated_apple_log(log_output, identifier, submitted)
        advance("accepted", appleLog=apple_log)
    export_apple_receipts(root, project, destination.name, receipts.data["appleLog"], identifier)
    final = root / "final" / destination.name
    checksum = final.with_name(final.name + ".sha256")
    if not receipts.reached("final-verified"):
        state.ensure_private_directory(final.parent)
        # Our unpromoted copy may have been partially stapled. Recreate only it.
        for path in (final, checksum):
            if os.path.lexists(path):
                status = path.lstat()
                if (not stat.S_ISREG(status.st_mode) or status.st_uid != os.geteuid() or
                        status.st_nlink != 1 or stat.S_IMODE(status.st_mode) not in {0o400, 0o600}):
                    raise transaction.ReleaseTransactionError("Unpromoted work copy is unsafe")
                path.unlink()
        immutable(lambda: snapshot.snapshot_release_input(submitted.path, final, maximum_bytes=MAX_BYTES))
        call(["xcrun", "stapler", "staple", str(final)])
        fault("stapled")
        final_seal = transaction.seal_regular_file(final, maximum_bytes=MAX_BYTES)
        checksum_seal = transaction.write_checksum_sidecar(final_seal, checksum)
        immutable(lambda: transaction.observe_sealed_phase(final_seal, lambda:
            transaction.observe_sealed_phase(checksum_seal, lambda:
                verify_image_copy(final_seal, lambda image:
                    call([str(project / "scripts/verify-direct-notarized-dmg.sh"), str(image)])),
                maximum_bytes=4096), maximum_bytes=MAX_BYTES))
        immutable(lambda: transaction.observe_sealed_phase(final_seal, lambda:
            verify_image_copy(final_seal, lambda image:
                qualify(project, image, archive.path, runner, manifest.path, data["channel"])), maximum_bytes=MAX_BYTES))
        advance("final-verified", final=encode_seal(final_seal), checksum=encode_seal(checksum_seal))
    final_seal = decode_seal(receipts.data["final"], final)
    checksum_seal = decode_seal(receipts.data["checksum"], checksum)
    # Publication helper checks exact retained inode/hash, including interrupted links.
    for stage, seal, output in (
            ("sidecar-committed", checksum_seal, destination.with_name(destination.name + ".sha256")),
            ("dmg-committed", final_seal, destination)):
        transaction.publish_or_adopt_sealed_file(seal, destination=output,
                                               maximum_bytes=MAX_BYTES)
        fault("published-" + stage)
        if not receipts.reached(stage):
            advance(stage)
    if not receipts.reached("complete"):
        advance("complete")
    return {"status": "complete", "submissionID": identifier, "sha256": final_seal.sha256}


def validated_apple_log(output, identifier, submitted):
    """Keep only release fields, and bind Apple's accepted log to submitted bytes."""
    if len(output.encode("utf-8")) > 8 * 1024**2:
        raise DMGError("Apple log exceeds its limit")
    payload = json.loads(output, object_pairs_hook=reject_duplicates)
    if (not isinstance(payload, dict) or payload.get("jobId") != identifier or
            payload.get("status") != "Accepted" or payload.get("statusCode") != 0 or
            payload.get("issues") is not None or payload.get("sha256") != submitted.sha256 or
            payload.get("archiveFilename") != submitted.path.name or
            not isinstance(payload.get("ticketContents"), list)):
        raise DMGError("Apple log does not match accepted DMG submission")
    tickets = []
    for item in payload["ticketContents"]:
        if not isinstance(item, dict):
            raise DMGError("Apple ticket is invalid")
        path = item.get("path")
        if (not isinstance(path, str) or ".." in Path(path).parts or
                not (path == submitted.path.name or path.startswith(submitted.path.name + "/")) or
                not re.fullmatch(r"[0-9a-f]{40}", str(item.get("cdhash"))) or
                item.get("arch") not in {None, "arm64"}):
            raise DMGError("Apple ticket path or signature is invalid")
        tickets.append({k: v for k, v in item.items() if k in {"path", "cdhash", "arch", "digestAlgorithm"}})
    for expected in (submitted.path.name, submitted.path.name + "/NeAntik.app",
                     submitted.path.name + "/NeAntik.app/Contents/Resources/NeAntik Browser.app"):
        if sum(ticket["path"] == expected for ticket in tickets) != 1:
            raise DMGError("Apple log lacks an unambiguous required signature ticket")
    return {**{k: payload[k] for k in ("jobId", "status", "statusCode", "archiveFilename", "sha256")},
            "issues": None, "ticketContents": tickets}


def export_apple_receipts(root, project, name, apple_log, identifier):
    """Keep the existing diagnostic file contract, without overwriting old receipts."""
    destination = project / "dist/notary"
    destination.mkdir(mode=0o700, exist_ok=True)
    canonical(destination)
    for suffix, payload in ((".notary-receipt.json", apple_log),
                            (".notary-submit.log", {"id": identifier, "status": "Accepted"})):
        retained = root / (name + suffix)
        if not os.path.lexists(retained):
            notary.write_private_json(retained, payload)
        seal = transaction.seal_regular_file(retained, maximum_bytes=8 * 1024**2,
                                             allowed_link_counts=frozenset({1, 2}))
        with retained.open("rb") as stream:
            if json.load(stream, object_pairs_hook=reject_duplicates) != payload:
                raise DMGError("Retained Apple receipt changed")
        transaction.publish_or_adopt_sealed_file(seal, destination=destination / retained.name,
                                               maximum_bytes=8 * 1024**2)


def start(root, project, destination, profile, dmg, archive, *, capture=source.capture_release_source,
          candidate_manifest=None):
    """Copy inputs once. No rebuild, signing, or Apple action occurs here."""
    for path in (root, project, destination, dmg, archive):
        canonical(path)
    if os.path.lexists(root) or os.path.lexists(destination) or os.path.lexists(destination.with_name(destination.name + ".sha256")):
        raise DMGError("Transaction or destination already exists")
    state.ensure_private_directory(root)
    notary.write_private_json(root / "reservation.json", {
        "schema": 1, "project": str(project), "destination": str(destination),
        "profile": profile,
    })
    for name in ("submitted", "archive", "final", "candidate"):
        state.ensure_private_directory(root / name)
    if not re.fullmatch(r"NeAntik-[0-9]+\.[0-9]+\.[0-9]+-arm64-notarized\.dmg", destination.name) or archive.name != destination.with_suffix(".zip").name:
        raise DMGError("DMG/ZIP names do not agree")
    captured = capture(project, closure=POLICY_CLOSURE)
    seals = {}
    submitted = root / "submitted" / destination.name
    snapshot.snapshot_release_input(dmg, submitted, maximum_bytes=MAX_BYTES)
    seals["submitted"] = encode_seal(transaction.seal_regular_file(submitted, maximum_bytes=MAX_BYTES))
    pinned_archive = root / "archive" / archive.name
    pinned_checksum, archive_record, checksum_record, expected_zip = copy_notary_zip(archive, pinned_archive)
    archive_seal = transaction.seal_regular_file(pinned_archive, maximum_bytes=MAX_BYTES)
    checksum_seal = transaction.seal_regular_file(pinned_checksum, maximum_bytes=4096)
    if ((archive_seal.sha256, archive_seal.size) != (archive_record["sha256"], archive_record["bytes"]) or
            (checksum_seal.sha256, checksum_seal.size) != (checksum_record["sha256"], checksum_record["bytes"]) or
            archive_seal.sha256 != expected_zip):
        raise DMGError("Copied notary ZIP inputs changed before binding")
    seals["archive"] = encode_seal(archive_seal)
    transaction.assert_checksum_matches_archive(decode_seal(seals["archive"], root / "archive" / archive.name), checksum_seal)
    seals["archiveChecksum"] = encode_seal(checksum_seal)
    candidate = root / "candidate/direct-candidate-manifest.json"
    snapshot.snapshot_release_input(candidate_manifest or project / "dist/direct-candidate-manifest.json", candidate,
                                    maximum_bytes=16 * 1024**2)
    manifest_seal = transaction.seal_regular_file(candidate, maximum_bytes=16 * 1024**2)
    with candidate.open("rb") as stream:
        channel = json.load(stream, object_pairs_hook=reject_duplicates).get("releaseChannel")
    if channel not in {"public-alpha", "production"}:
        raise DMGError("Candidate release channel is invalid")
    transaction.assert_sealed(manifest_seal, maximum_bytes=16 * 1024**2)
    seals["manifest"] = encode_seal(manifest_seal)
    source.assert_release_source_unchanged(captured)
    Receipts(root).append("created", project=str(project), destination=str(destination),
                          profile=profile, source=captured.payload, channel=channel, **seals)


def existing_transactions(private, destination):
    """A new CLI invocation cannot hide an uncertain earlier submission."""
    found = []
    for root in sorted(private.iterdir()):
        if not re.fullmatch(r"[0-9a-f]{32}", root.name):
            continue  # Per-image lock files live in this same namespace.
        canonical(root)
        state.ensure_private_directory(root)
        reservation = root / "reservation.json"
        if not os.path.lexists(reservation):
            raise DMGError("Uninitialized retained transaction requires inspection")
        payload, _ = read_receipt(reservation)
        if (not isinstance(payload, dict) or set(payload) !=
                {"schema", "project", "destination", "profile"} or payload["schema"] != 1):
            raise DMGError("Retained transaction reservation is invalid")
        if payload["destination"] == str(destination):
            found.append(root)
    return found


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project-root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--destination", type=Path, required=True)
    parser.add_argument("--notary-profile", default="neantik-notary")
    parser.add_argument("--resume", type=Path)
    parser.add_argument("--dmg", type=Path)
    parser.add_argument("--zip", type=Path)
    parser.add_argument("--candidate-manifest", type=Path)
    parser.add_argument("--check-new", action="store_true", help="Refuse an existing retained transaction before packaging")
    args = parser.parse_args()
    lock = -1
    try:
        project = canonical(args.project_root)
        destination = canonical(args.destination)
        if destination.parent != project / "dist":
            raise DMGError("Destination must be the project dist directory")
        private = project / "dist/private/dmg-transactions"
        canonical(private)
        state.ensure_private_directory(private.parent)
        state.ensure_private_directory(private)
        lock = state.acquire_transaction_lock(private, destination.name)
        if args.check_new:
            retained = existing_transactions(private, destination)
            if retained:
                print("Existing DMG transaction: " + str(retained[0]), flush=True)
            if args.resume or args.dmg or args.zip or retained:
                raise DMGError("Retained transaction exists; use explicit resume")
            print('{"status":"new-transaction-allowed"}')
            return 0
        if args.resume:
            root = canonical(args.resume)
            if root.parent != private or not re.fullmatch(r"[0-9a-f]{32}", root.name) or args.dmg or args.zip:
                raise DMGError("Resume root or arguments are invalid")
        else:
            if not args.dmg or not args.zip:
                raise DMGError("Start requires both prepared DMG and qualified ZIP")
            retained = existing_transactions(private, destination)
            if retained:
                print("Existing DMG transaction: " + str(retained[0]), flush=True)
                raise DMGError("Use explicit resume; a new submit is forbidden")
            with (project / "Resources/Info.plist").open("rb") as stream:
                version = plistlib.load(stream)["CFBundleShortVersionString"]
            if destination.name != f"NeAntik-{version}-arm64-notarized.dmg":
                raise DMGError("Destination version differs from the current candidate")
            root = private / uuid.uuid4().hex
            print("DMG transaction retained at: " + str(root), flush=True)
            manifest = canonical(args.candidate_manifest or project / "dist/direct-candidate-manifest.json")
            if manifest != project / "dist/direct-candidate-manifest.json":
                if manifest.name != "direct-candidate-manifest.json":
                    raise DMGError("Candidate manifest basename is invalid")
                location.validate(project, manifest.parent)
            start(root, project, destination, args.notary_profile, canonical(args.dmg), canonical(args.zip),
                  candidate_manifest=manifest)
        result = run(root, project, destination, args.notary_profile,
                     progress=lambda stage: print("DMG stage: " + stage, flush=True))
        print(json.dumps(result, sort_keys=True))
    except DMGError as error:
        # Our messages are fixed labels, never raw command/account output.
        print("DMG continuation refused: " + str(error), file=sys.stderr)
        return 65
    except Exception as error:
        # Do not include external output/paths/account data in diagnostics.
        print("DMG continuation refused (" + type(error).__name__ + "); retained state requires inspection. No automatic resubmission.", file=sys.stderr)
        return 65
    finally:
        if lock >= 0:
            os.close(lock)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
