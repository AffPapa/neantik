#!/usr/bin/env python3
"""Verify exact Direct artifacts when macOS local policy services are unavailable.

This is not a generic notarization bypass. It is allowed only when:
* artifact bytes match release.json and their sidecars;
* the ZIP has a completed, Accepted, source-bound Direct transaction receipt;
* the DMG has an Accepted Apple notary receipt and matching ticket CDHashes;
* Developer ID signatures, timestamps, ARM64/runtime checks and disk-image CRC pass;
* stapler/spctl either pass or fail only with the known local Launch Services error.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import re
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path


class VerificationError(RuntimeError):
    pass


def run(command: list[str], *, allow_policy_unavailable: bool = False) -> str:
    completed = subprocess.run(
        command,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    output = completed.stdout.strip()
    if completed.returncode == 0:
        return output
    lowered = output.lower()
    policy_unavailable = (
        "klsdataunavailableerr" in lowered
        or "lsdataunavailable" in lowered
        or "internal error in code signing subsystem" in lowered
    )
    if allow_policy_unavailable and policy_unavailable:
        return "local-policy-tool-unavailable: " + output
    raise VerificationError(
        f"command failed ({completed.returncode}): {' '.join(command)}\n{output}"
    )


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_json(path: Path) -> dict[str, object]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise VerificationError(f"invalid JSON evidence: {path}: {error}") from error
    if not isinstance(value, dict):
        raise VerificationError(f"JSON evidence must be an object: {path}")
    return value


def artifact_map(
    manifest: dict[str, object],
) -> dict[str, dict[str, object]]:
    raw = manifest.get("artifacts")
    if not isinstance(raw, list):
        raise VerificationError("release.json artifacts must be an array")
    result: dict[str, dict[str, object]] = {}
    for item in raw:
        if not isinstance(item, dict) or item.get("format") not in {"dmg", "zip"}:
            raise VerificationError("release.json contains an invalid artifact")
        result[str(item["format"])] = item
    if set(result) != {"dmg", "zip"}:
        raise VerificationError("release.json must contain one DMG and one ZIP")
    return result


def verify_artifact_bytes(
    directory: Path,
    artifact: dict[str, object],
) -> Path:
    filename = str(artifact["filename"])
    path = directory / filename
    sidecar = directory / f"{filename}.sha256"
    if not path.is_file() or path.is_symlink():
        raise VerificationError(f"artifact is missing or unsafe: {path}")
    if not sidecar.is_file() or sidecar.is_symlink():
        raise VerificationError(f"checksum sidecar is missing or unsafe: {sidecar}")
    expected_size = int(artifact["sizeBytes"])
    expected_hash = str(artifact["sha256"])
    if path.stat().st_size != expected_size:
        raise VerificationError(f"artifact size mismatch: {filename}")
    actual_hash = sha256(path)
    if actual_hash != expected_hash:
        raise VerificationError(f"artifact SHA-256 mismatch: {filename}")
    fields = sidecar.read_text(encoding="utf-8").split()
    if fields != [expected_hash, filename]:
        raise VerificationError(f"checksum sidecar is not canonical: {sidecar}")
    return path


def codesign_fields(path: Path) -> dict[str, list[str]]:
    output = run(["codesign", "--display", "--verbose=4", str(path)])
    fields: dict[str, list[str]] = {}
    for line in output.splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        fields.setdefault(key, []).append(value)
    return fields


def require_developer_id(
    path: Path,
    *,
    expected_identifier: str | None = None,
) -> dict[str, list[str]]:
    run(["codesign", "--verify", "--deep", "--strict", "--verbose=2", str(path)])
    fields = codesign_fields(path)
    authorities = fields.get("Authority", [])
    if not any(
        value.startswith("Developer ID Application:") for value in authorities
    ):
        raise VerificationError(f"Developer ID authority is missing: {path}")
    if fields.get("TeamIdentifier") != ["H6VGU2M6JD"]:
        raise VerificationError(f"unexpected Developer ID team: {path}")
    if not fields.get("Timestamp"):
        raise VerificationError(f"trusted timestamp is missing: {path}")
    if expected_identifier and fields.get("Identifier") != [expected_identifier]:
        raise VerificationError(f"unexpected signature identifier: {path}")
    return fields


def ticket_cdhash(
    receipt: dict[str, object],
    *,
    exact_path: str,
) -> str:
    tickets = receipt.get("ticketContents")
    if not isinstance(tickets, list):
        raise VerificationError("DMG notary receipt has no ticketContents")
    matches = [
        item
        for item in tickets
        if isinstance(item, dict) and item.get("path") == exact_path
    ]
    if len(matches) != 1:
        raise VerificationError(f"DMG notary receipt lacks exact ticket: {exact_path}")
    value = matches[0].get("cdhash")
    if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{40}", value):
        raise VerificationError(f"invalid ticket CDHash for {exact_path}")
    return value


def verify_zip(
    *,
    project_root: Path,
    directory: Path,
    manifest: dict[str, object],
    artifact: dict[str, object],
) -> tuple[Path, str, str]:
    archive = verify_artifact_bytes(directory, artifact)
    filename = archive.name
    receipts = sorted(
        (project_root / "dist" / ".notary-receipts").glob(
            f"{filename}.*.receipt.json"
        )
    )
    matching: list[dict[str, object]] = []
    for receipt_path in receipts:
        receipt = load_json(receipt_path)
        final = receipt.get("finalArchive")
        source = receipt.get("releaseSource")
        apple = receipt.get("appleSubmission")
        if (
            receipt.get("receiptType") == "direct-release"
            and receipt.get("publicationState") == "transaction-verified"
            and receipt.get("archiveName") == filename
            and isinstance(final, dict)
            and final.get("sha256") == artifact["sha256"]
            and final.get("size") == artifact["sizeBytes"]
            and isinstance(apple, dict)
            and apple.get("status") == "Accepted"
            and isinstance(source, dict)
            and isinstance(source.get("git"), dict)
            and source["git"].get("commit")
            == manifest["source"]["commit"]  # type: ignore[index]
        ):
            matching.append(receipt)
    if len(matching) != 1:
        raise VerificationError(
            "expected exactly one completed source-bound ZIP receipt"
        )

    inspector = json.loads(
        run(
            [
                sys.executable,
                str(project_root / "scripts" / "notary_transaction_inspector.py"),
                "--project-root",
                str(project_root),
                "--json",
            ]
        )
    )
    if not (
        inspector.get("safe") is True
        and inspector.get("releaseReady") is True
        and inspector.get("summary", {}).get("releaseBlockingCount") == 0
    ):
        raise VerificationError("notary transaction history is not release-ready")

    module_path = project_root / "scripts" / "verify-direct-notarized-archive.py"
    spec = importlib.util.spec_from_file_location(
        "verify_direct_notarized_archive",
        module_path,
    )
    if spec is None or spec.loader is None:
        raise VerificationError("cannot load ZIP verifier")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    module.verify_archive(
        archive=archive,
        project_root=project_root,
        allow_local_policy_tool_unavailable=True,
    )

    with tempfile.TemporaryDirectory(prefix="neantik-release-fallback-") as temp:
        root = Path(temp)
        run(["ditto", "-x", "-k", str(archive), str(root)])
        app = root / "NeAntik.app"
        runtime = app / "Contents" / "Resources" / "NeAntik Browser.app"
        app_fields = require_developer_id(
            app,
            expected_identifier="app.neantik.desktop",
        )
        runtime_fields = require_developer_id(
            runtime,
            expected_identifier="app.neantik.runtime",
        )
        return (
            archive,
            app_fields["CDHash"][0],
            runtime_fields["CDHash"][0],
        )


def verify_dmg(
    *,
    project_root: Path,
    directory: Path,
    artifact: dict[str, object],
    app_cdhash: str,
    runtime_cdhash: str,
) -> Path:
    image = verify_artifact_bytes(directory, artifact)
    run(["hdiutil", "verify", str(image)])
    fields = require_developer_id(image)

    receipt_path = (
        project_root / "dist" / "notary" / f"{image.name}.notary-receipt.json"
    )
    submit_log_path = (
        project_root / "dist" / "notary" / f"{image.name}.notary-submit.log"
    )
    receipt = load_json(receipt_path)
    submit = load_json(submit_log_path)
    job_id = str(receipt.get("jobId", ""))
    try:
        uuid.UUID(job_id)
    except ValueError as error:
        raise VerificationError("DMG receipt jobId is invalid") from error
    if not (
        receipt.get("status") == "Accepted"
        and receipt.get("statusCode") == 0
        and receipt.get("issues") is None
        and receipt.get("archiveFilename") == image.name
        and submit.get("id") == job_id
        and submit.get("status") == "Accepted"
    ):
        raise VerificationError("DMG Apple Accepted evidence is incomplete")

    prefix = image.name
    if ticket_cdhash(receipt, exact_path=prefix) != fields["CDHash"][0]:
        raise VerificationError("final DMG signature does not match Apple ticket")
    if (
        ticket_cdhash(receipt, exact_path=f"{prefix}/NeAntik.app")
        != app_cdhash
    ):
        raise VerificationError("DMG app ticket does not match verified ZIP app")
    if (
        ticket_cdhash(
            receipt,
            exact_path=(
                f"{prefix}/NeAntik.app/Contents/Resources/"
                "NeAntik Browser.app"
            ),
        )
        != runtime_cdhash
    ):
        raise VerificationError("DMG runtime ticket does not match verified ZIP runtime")

    tickets = receipt["ticketContents"]
    if any(
        isinstance(item, dict) and item.get("arch") not in {None, "arm64"}
        for item in tickets  # type: ignore[union-attr]
    ):
        raise VerificationError("DMG Apple ticket contains a non-ARM64 component")

    run(
        ["xcrun", "stapler", "validate", str(image)],
        allow_policy_unavailable=True,
    )
    run(
        [
            "spctl",
            "--assess",
            "--type",
            "open",
            "--context",
            "context:primary-signature",
            "--verbose=4",
            str(image),
        ],
        allow_policy_unavailable=True,
    )
    return image


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-root", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--directory", type=Path, required=True)
    args = parser.parse_args()
    project_root = args.project_root.resolve()
    manifest_path = args.manifest.resolve()
    directory = args.directory.resolve()
    try:
        manifest = load_json(manifest_path)
        artifacts = artifact_map(manifest)
        _, app_cdhash, runtime_cdhash = verify_zip(
            project_root=project_root,
            directory=directory,
            manifest=manifest,
            artifact=artifacts["zip"],
        )
        verify_dmg(
            project_root=project_root,
            directory=directory,
            artifact=artifacts["dmg"],
            app_cdhash=app_cdhash,
            runtime_cdhash=runtime_cdhash,
        )
    except (
        KeyError,
        OSError,
        VerificationError,
        json.JSONDecodeError,
    ) as error:
        print(f"Direct local-policy fallback failed: {error}", file=sys.stderr)
        return 1
    print(
        "PASS: exact DMG/ZIP verified through Apple receipts, "
        "Developer ID, CRC, source-bound transaction and local-policy fallback."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
