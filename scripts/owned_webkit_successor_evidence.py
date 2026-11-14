"""Verify the pinned evidence for a private owned-WebKit Dev QA package.

The caller supplies the reviewed manifest SHA-256 independently. This module
binds the local source, notices, stage receipt and final runtime bytes. The
caller must separately verify code signatures and all public release gates.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import unicodedata

import webkit_network_sandbox_pin as sandbox_pin


class EvidenceError(ValueError):
    pass


MAX_EVIDENCE_BYTES = 4 * 1024 * 1024
MAX_NOTICE_FILES = 256
MAX_RUNTIME_ENTRIES = 100_000
MAX_IMAGES = 128
WEBKIT_IMAGE = "WebKit.framework/Versions/A/WebKit"
MACHO_MAGICS = {bytes.fromhex(value) for value in (
    "cffaedfe", "cefaedfe", "feedfacf", "feedface", "cafebabe", "bebafeca", "cafebabf", "bfbafeca"
)}
HUNK_LABEL = re.compile(rb"(?m)^(@@ -\d+(?:,\d+)? \+\d+(?:,\d+)? @@)[^\r\n]*$")


def _require(condition: bool, reason: str) -> None:
    if not condition:
        raise EvidenceError(reason)


def _fields(value: object, names: str, label: str) -> dict:
    _require(isinstance(value, dict) and set(value) == set(names.split()),
             f"invalid {label} fields")
    return value


def _hex(value: object, length: int = 64) -> str:
    _require(isinstance(value, str) and re.fullmatch(f"[a-f0-9]{{{length}}}", value) is not None,
             "invalid evidence digest")
    return value


def _relative(value: object) -> str:
    _require(isinstance(value, str) and 0 < len(value) <= 1024
             and not any(c in value for c in ("\\", ":"))
             and not any(ord(c) < 32 or ord(c) == 127 for c in value), "invalid relative evidence path")
    path = PurePosixPath(value)
    _require(not path.is_absolute() and path.as_posix() == value
             and bool(path.parts) and ".." not in path.parts, "invalid relative evidence path")
    return value


def _physical(value: object, directory: bool = False) -> Path:
    _require(isinstance(value, (Path, str)), "invalid evidence path")
    path = Path(value)
    _require(path.is_absolute() and path.as_posix() == str(value)
             and ".." not in path.parts and path.resolve(strict=True) == path,
             "evidence path must be canonical and physical")
    kind = path.lstat().st_mode
    _require(stat.S_ISDIR(kind) if directory else stat.S_ISREG(kind), "unsafe evidence file type")
    return path


def _bytes(path: Path) -> bytes:
    with path.open("rb") as stream:
        data = stream.read(MAX_EVIDENCE_BYTES + 1)
    _require(0 < len(data) <= MAX_EVIDENCE_BYTES, "invalid evidence byte count")
    return data


def _pinned_bytes(path: Path, expected: str) -> bytes:
    data = _bytes(path)
    _require(hashlib.sha256(data).hexdigest() == _hex(expected), "pinned evidence bytes changed")
    return data


def _ref(value: object) -> tuple[Path, str, bytes]:
    row = _fields(value, "path sha256", "evidence reference")
    path = _physical(row["path"])
    expected = _hex(row["sha256"])
    return path, expected, _pinned_bytes(path, expected)


def _object_pairs(pairs: list[tuple[str, object]]) -> dict:
    value = dict(pairs)
    _require(len(value) == len(pairs), "duplicate evidence JSON key")
    return value


def _json(data: bytes) -> dict:
    value = json.loads(data.decode("utf-8"), object_pairs_hook=_object_pairs)
    _require(isinstance(value, dict), "evidence JSON must be an object")
    return value


def _schema(value: dict, scope: str) -> None:
    _require(type(value["schemaVersion"]) is int and value["schemaVersion"] == 1
             and value["scope"] == scope, "unsupported private evidence schema or scope")


def _git(checkout: Path, *args: str) -> bytes:
    env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
               GIT_NO_LAZY_FETCH="1", GIT_TERMINAL_PROMPT="0", LC_ALL="C")
    result = subprocess.run(
        ["/usr/bin/git", "--no-optional-locks", "--no-replace-objects", "--no-pager",
         "-C", str(checkout), "-c", "core.fsmonitor=false", *args],
        env=env, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=30, check=True,
    )
    _require(len(result.stdout) <= MAX_EVIDENCE_BYTES, "Git source evidence is too large")
    return result.stdout


def _verify_source(value: object) -> dict:
    source = _fields(value, "checkout upstreamCommit upstreamTree patchedCommit patchedTree patch", "source")
    checkout = _physical(source["checkout"], directory=True)
    upstream, patched = (_hex(source[key], 40) for key in ("upstreamCommit", "patchedCommit"))
    upstream_tree, patched_tree = (_hex(source[key], 40) for key in ("upstreamTree", "patchedTree"))
    _, _, patch = _ref(source["patch"])
    _require(_git(checkout, "rev-parse", "--show-toplevel").rstrip(b"\n") == os.fsencode(checkout)
             and _git(checkout, "rev-parse", "HEAD", "HEAD^{tree}").splitlines()
             == [patched.encode(), patched_tree.encode()]
             and _git(checkout, "rev-parse", f"{upstream}^{{tree}}").strip() == upstream_tree.encode()
             and _git(checkout, "rev-list", "--parents", "-n", "1", patched).split()
             == [patched.encode(), upstream.encode()], "local WebKit Git provenance mismatch")
    _require(not _git(checkout, "status", "--porcelain=v1", "--untracked-files=normal"),
             "local WebKit source checkout has changes")
    git_patch = _git(checkout, "diff", "--no-ext-diff", "--no-textconv", "--no-color", "--no-renames",
                     "--binary", "--full-index", "--src-prefix=a/", "--dst-prefix=b/", "--unified=3",
                     "--diff-algorithm=myers", "--indent-heuristic", upstream, patched, "--")
    # Attributes can change display-only hunk names without changing patch application.
    _require(bool(git_patch) and HUNK_LABEL.sub(rb"\1", git_patch) == HUNK_LABEL.sub(rb"\1", patch),
             "reviewed WebKit source patch differs from the Git tree delta")
    return source


def _verify_stage(manifest: dict, receipt: dict, upstream: str) -> tuple[str, dict]:
    _require(receipt.get("status") == "staged-pre-sign-only" and receipt.get("upstreamCommit") == upstream
             and receipt.get("signingRequired") is True and receipt.get("launchQualified") is False
             and isinstance(manifest.get("upstream"), dict)
             and manifest["upstream"].get("repository") == "WebKit/WebKit"
             and manifest["upstream"].get("commit") == upstream, "WebKit staging identity mismatch")
    policy = receipt.get("networkSandbox")
    config = manifest.get("networkSandbox")
    _require(isinstance(policy, dict) and isinstance(config, dict)
             and policy.get("path") == config.get("path") == sandbox_pin.RELATIVE_PATH.as_posix()
             and type(policy.get("policyRevision")) is int
             and policy["policyRevision"] == config.get("policyRevision") == 13
             and type(policy.get("relayPort")) is int and policy["relayPort"] == config.get("relayPort")
             and 1 <= policy["relayPort"] <= 65535
             and policy.get("removedInheritedNetworkStarGrant") is True
             and policy.get("removedDelegatedSystemNetworkInvocation") is True
             and policy.get("removedNetworkServiceProxyTokenGrant") is True,
             "reviewed WebKit staging policy mismatch")
    base = _hex(policy.get("baseSHA256"))
    patched = _hex(policy.get("patchedSHA256"))
    _require(base == config.get("baseSHA256") and base != patched, "staged WebKit sandbox was not patched")
    images = receipt.get("machOSHA256")
    _require(isinstance(images, dict) and 0 < len(images) <= MAX_IMAGES and WEBKIT_IMAGE in images
             and type(receipt.get("machOCount")) is int and receipt["machOCount"] == len(images),
             "invalid staged WebKit image inventory")
    return patched, {_relative(path): _hex(sha) for path, sha in images.items()}


def _verify_notices(value: dict, source: dict, stage_digest: str) -> tuple[dict[str, Path], dict[str, str]]:
    inventory = _fields(value, "schemaVersion scope patchedCommit patchedTree stageReceiptSHA256 notices",
                        "local QA inventory")
    _schema(inventory, "local-corresponding-source-dev-qa")
    _require(inventory["patchedCommit"] == source["patchedCommit"]
             and inventory["patchedTree"] == source["patchedTree"]
             and inventory["stageReceiptSHA256"] == stage_digest, "local QA inventory identity mismatch")
    notices = inventory["notices"]
    _require(isinstance(notices, dict) and 0 < len(notices) <= MAX_NOTICE_FILES, "invalid QA notice inventory")
    files = {}
    hashes = {}
    for destination, ref in notices.items():
        destination = _relative(destination)
        files[destination], hashes[destination], _ = _ref(ref)
    destinations = {unicodedata.normalize("NFD", path).casefold() for path in files}
    _require(len(destinations) == len(files)
             and not any(parent.as_posix() in destinations for path in destinations
                         for parent in PurePosixPath(path).parents), "colliding QA notice destinations")
    return files, hashes


def verify_signed_image_binding(value: dict, stage: dict) -> dict[str, str]:
    """Validate the signer’s complete pre-sign to signed image hash map."""
    binding = _fields(value, "schemaVersion status imageCount images", "signed runtime image binding")
    rows = binding["images"]
    _require(type(binding["schemaVersion"]) is int and binding["schemaVersion"] == 1
             and binding["status"] == "recipient-signed-runtime-image-binding"
             and isinstance(rows, list) and type(binding["imageCount"]) is int
             and binding["imageCount"] == len(rows) == len(stage), "invalid signed WebKit image binding")
    result = {}
    for row in rows:
        image = _fields(row, "path sourceInputSHA256 relocatedSHA256 recipientSignedSHA256 rpathChange",
                        "signed runtime image")
        path = _relative(image["path"])
        _require(path not in result and stage.get(path) == _hex(image["sourceInputSHA256"]),
                 "signed WebKit image differs from staging receipt")
        _hex(image["relocatedSHA256"])
        result[path] = _hex(image["recipientSignedSHA256"])
    return result


def verify_runtime_images(runtime: Path, signed: dict[str, str]) -> None:
    """Verify exact hashes and completeness of the physical Mach-O inventory."""
    seen = set()
    # os.walk propagates directory read failures through onerror. Path.rglob can
    # silently suppress them, leaving unseen files outside the signed inventory.
    def walk_error(error: OSError) -> None:
        raise error

    entries = 0
    for directory, directories, files in os.walk(runtime, onerror=walk_error, followlinks=False):
        entries += len(directories) + len(files)
        _require(entries <= MAX_RUNTIME_ENTRIES, "runtime inventory exceeds its bound")
        for name in directories + files:
            item = Path(directory) / name
            kind = item.lstat().st_mode
            if stat.S_ISLNK(kind):
                _require(item.resolve(strict=True).is_relative_to(runtime), "runtime symlink escapes its root")
            elif not stat.S_ISDIR(kind):
                _require(stat.S_ISREG(kind), "unsafe file in signed WebKit runtime")
                path = item.relative_to(runtime).as_posix()
                with item.open("rb") as stream:
                    magic = stream.read(4)
                    if magic not in MACHO_MAGICS:
                        _require(path not in signed, "bound signed WebKit image is not Mach-O")
                        continue
                    _require(path in signed, "unbound Mach-O in signed WebKit runtime")
                    digest = hashlib.sha256(magic)
                    for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                        digest.update(chunk)
                _require(digest.hexdigest() == signed[path], "signed WebKit image bytes changed")
                seen.add(path)
    _require(seen == set(signed), "missing Mach-O in signed WebKit runtime")


def verify(manifest_path: Path, expected_manifest_sha256: str, runtime_frameworks: Path) -> dict:
    """Bind exact source/QA evidence and the signed Frameworks input, without modifying them."""
    try:
        manifest = _fields(_json(_pinned_bytes(_physical(manifest_path), expected_manifest_sha256)),
                           "schemaVersion scope source stagingManifest stageReceipt qaInventory signedRuntimeImageBinding",
                           "successor manifest")
        _schema(manifest, "private-owned-webkit-dev-qa")
        runtime = _physical(runtime_frameworks, directory=True)
        source = _verify_source(manifest["source"])
        _, _, stage_config = _ref(manifest["stagingManifest"])
        _, stage_digest, stage_receipt = _ref(manifest["stageReceipt"])
        sandbox, stage = _verify_stage(_json(stage_config), _json(stage_receipt), source["upstreamCommit"])
        _, _, inventory = _ref(manifest["qaInventory"])
        notices, notice_hashes = _verify_notices(_json(inventory), source, stage_digest)
        binding_path, binding_digest, binding = _ref(manifest["signedRuntimeImageBinding"])
        signed = verify_signed_image_binding(_json(binding), stage)
        sandbox_pin.verify(runtime, sandbox)
        verify_runtime_images(runtime, signed)
        return {"manifestSHA256": expected_manifest_sha256, "networkSandboxSHA256": sandbox,
                "signedRuntimeImageBinding": binding_path, "signedRuntimeImageBindingSHA256": binding_digest,
                "noticeFiles": notices, "noticeSHA256": notice_hashes,
                "webkitCommit": source["patchedCommit"], "webkitTree": source["patchedTree"],
                "releaseQualified": False}
    except EvidenceError:
        raise
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        raise EvidenceError("cannot verify private WebKit successor evidence") from error
