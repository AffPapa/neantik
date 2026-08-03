#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import re
import stat
import sys
import unicodedata
import zipfile
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Iterator


GUI_VERIFIER_PATH = (
    Path(__file__).resolve().parent / "verify-gui-fingerprint-report.py"
)
GUI_SPEC = importlib.util.spec_from_file_location(
    "verify_gui_fingerprint_report_for_public_privacy",
    GUI_VERIFIER_PATH,
)
if GUI_SPEC is None or GUI_SPEC.loader is None:
    raise RuntimeError("Cannot load GUI fingerprint semantic verifier.")
GUI_VERIFIER = importlib.util.module_from_spec(GUI_SPEC)
sys.modules[GUI_SPEC.name] = GUI_VERIFIER
GUI_SPEC.loader.exec_module(GUI_VERIFIER)
EVIDENCE_SCHEMA_PATH = (
    Path(__file__).resolve().parent / "fingerprint_evidence_schema8.py"
)
EVIDENCE_SPEC = importlib.util.spec_from_file_location(
    "fingerprint_evidence_schema8_for_public_privacy",
    EVIDENCE_SCHEMA_PATH,
)
if EVIDENCE_SPEC is None or EVIDENCE_SPEC.loader is None:
    raise RuntimeError("Cannot load schema-8 fingerprint verifier.")
EVIDENCE_SCHEMA = importlib.util.module_from_spec(EVIDENCE_SPEC)
sys.modules[EVIDENCE_SPEC.name] = EVIDENCE_SCHEMA
EVIDENCE_SPEC.loader.exec_module(EVIDENCE_SCHEMA)

SOURCE_SUFFIXES = {
    ".c",
    ".cc",
    ".command",
    ".cpp",
    ".css",
    ".h",
    ".hpp",
    ".js",
    ".m",
    ".mdx",
    ".mjs",
    ".mm",
    ".py",
    ".sh",
    ".swift",
    ".ts",
    ".tsx",
    ".zsh",
}
SAFE_BINARY_SIGNATURES = {
    ".gif": (b"GIF87a", b"GIF89a"),
    ".icns": (b"icns",),
    ".jpeg": (b"\xff\xd8\xff",),
    ".jpg": (b"\xff\xd8\xff",),
    ".pdf": (b"%PDF-",),
    ".png": (b"\x89PNG\r\n\x1a\n",),
    ".webp": (b"RIFF",),
}
TEXT_SUFFIXES = {
    "",
    ".conf",
    ".csv",
    ".env",
    ".html",
    ".ini",
    ".json",
    ".jsonl",
    ".log",
    ".md",
    ".plist",
    ".properties",
    ".rst",
    ".svg",
    ".toml",
    ".txt",
    ".xml",
    ".yaml",
    ".yml",
}
ASSIGNMENT_SUFFIXES = {
    ".conf",
    ".env",
    ".ini",
    ".json",
    ".jsonl",
    ".log",
    ".plist",
    ".properties",
    ".toml",
    ".txt",
    ".xml",
    ".yaml",
    ".yml",
}
CAPTURE_KEYS = {"directControl", "firstInitial", "firstRepeat", "second"}
SENSITIVE_JSON_KEYS = {
    "browsinghistory",
    "clientid",
    "cookie",
    "cookies",
    "credentials",
    "deviceid",
    "fingerprintseed",
    "history",
    "installationid",
    "installid",
    "password",
    "passphrase",
    "passwordvalue",
    "proxycredential",
    "proxycredentials",
    "proxyhost",
    "proxylogin",
    "proxypassword",
    "proxypasswordvalue",
    "proxypass",
    "proxypwd",
    "proxyusername",
    "profileid",
    "profilename",
    "pwd",
    "stableuserid",
    "userid",
    "urlhistory",
    "visitedurl",
}
SAFE_SECRET_MARKERS = {
    "",
    "<password>",
    "<redacted>",
    "none",
    "null",
    "redacted",
}
MAX_TEXT_FILE_BYTES = 16 * 1024 * 1024
MAX_BINARY_FILE_BYTES = 64 * 1024 * 1024
MAX_TOTAL_TEXT_BYTES = 128 * 1024 * 1024
MAX_TOTAL_ARTIFACT_BYTES = 256 * 1024 * 1024
PUBLIC_ATTESTATION_KEYS = {
    "auditSchemaVersion",
    "changedCriticalKeys",
    "candidateManifestSHA256",
    "createdAt",
    "identityCatalogVersion",
    "kind",
    "managerBuild",
    "managerVersion",
    "privateEvidenceSHA256",
    "productionIssues",
    "productionQualified",
    "publicAlphaIssues",
    "qualified",
    "releaseChannel",
    "runtimeCodeSignatureValid",
    "runtimeExecutableSHA256",
    "runtimeFlavor",
    "runtimeFrameworkSHA256",
    "runtimeName",
    "runtimeVersion",
    "schemaVersion",
    "unstableRequiredKeys",
}
AUTHENTICATED_PUBLIC_ATTESTATION_KEYS = {
    "schemaVersion",
    "kind",
    "releaseChannel",
    "candidateManifestSHA256",
    "authenticatedEvidenceID",
    "payloadSHA256",
    "transportSHA256",
    "privateEvidenceSHA256",
    "createdAt",
    "managerVersion",
    "managerBuild",
    "runtimeName",
    "runtimeVersion",
    "runtimeFlavor",
    "runtimeCodeSignatureValid",
    "runtimeExecutableSHA256",
    "runtimeFrameworkSHA256",
    "auditSchemaVersion",
    "identityCatalogVersion",
    "verdict",
    "changedCriticalKeys",
    "unavailableRequiredKeys",
    "unstableRequiredKeys",
    "publicAlphaQualified",
    "productionQualified",
    "limitations",
}

ABSOLUTE_USER_PATH_RE = re.compile(
    r"/Users/(?![<$\\{])"
    r"[A-Za-z0-9._-]+(?:/[^\s\"'<>]*)?"
)
IDENTITY_CODE_RE = re.compile(r"\bNA-[0-9A-Fa-f]{8}\b")
PROXY_URI_RE = re.compile(
    r"\b(?:https?|socks5h?)://([^:/@\s]+):([^/@\s]+)@"
    r"(?:\[[0-9A-Fa-f:]+\]|[^/\s]+)",
    re.IGNORECASE,
)
PROXY_PASSWORD_ASSIGNMENT_RE = re.compile(
    r"\bproxy(?:[_\s-]?)(?:password|pass|credentials?)\s*[:=]\s*"
    r"[\"']?([^,\s\"'}]+)",
    re.IGNORECASE,
)
BINARY_SENSITIVE_ASSIGNMENT_RE = re.compile(
    r"""(?ix)
    ["']?
    \b(?:
        password|passphrase|pwd|cookie|cookies|credentials?|
        proxy[_\s-]?(?:password|pass|credentials?|login|username)
    )
    ["']?\s*[:=]\s*["']?([^,;\s"'}]+)
    """
)


class PublicArtifactPrivacyError(RuntimeError):
    pass


@dataclass(frozen=True)
class Finding:
    entry: str
    kind: str


@dataclass(frozen=True)
class VerificationResult:
    artifact: Path
    scanned_entries: int
    scanned_bytes: int


@dataclass(frozen=True)
class ArtifactEntry:
    name: str
    payload: bytes
    is_binary: bool = False


def is_source_entry(name: str) -> bool:
    return PurePosixPath(name).suffix.lower() in SOURCE_SUFFIXES


def is_test_source_entry(name: str) -> bool:
    parts = {part.lower() for part in PurePosixPath(name).parts[:-1]}
    return "tests" in parts or "test" in parts or "fixtures" in parts


def is_text_entry(name: str) -> bool:
    suffix = PurePosixPath(name).suffix.lower()
    return suffix in TEXT_SUFFIXES or suffix in SOURCE_SUFFIXES


def validate_safe_binary(name: str, payload: bytes) -> None:
    suffix = PurePosixPath(name).suffix.lower()
    signatures = SAFE_BINARY_SIGNATURES.get(suffix)
    if signatures is None:
        raise PublicArtifactPrivacyError(
            f"Unknown public artifact file type cannot be privacy-verified: {name}"
        )
    if suffix == ".webp":
        valid = payload.startswith(b"RIFF") and payload[8:12] == b"WEBP"
    else:
        valid = any(payload.startswith(signature) for signature in signatures)
    if not valid:
        raise PublicArtifactPrivacyError(
            f"Safe binary extension has an invalid signature: {name}"
        )


def validate_binary_size(name: str, size: int) -> None:
    if size > MAX_BINARY_FILE_BYTES:
        raise PublicArtifactPrivacyError(
            "Binary entry is too large for deterministic privacy verification: "
            + name
        )


def read_bounded_payload(
    file: object,
    *,
    limit: int,
    name: str,
    kind: str,
) -> bytes:
    payload = file.read(limit + 1)
    if len(payload) > limit:
        raise PublicArtifactPrivacyError(
            f"{kind} entry is too large for deterministic privacy verification: "
            + name
        )
    return payload


def canonical_zip_member_name(info: zipfile.ZipInfo) -> str:
    name = info.filename
    if (
        not name
        or "\x00" in name
        or "\\" in name
        or unicodedata.normalize("NFC", name) != name
    ):
        raise PublicArtifactPrivacyError(
            f"Unsafe or non-canonical ZIP entry path prevents privacy verification: {name}"
        )
    if info.is_dir():
        if not name.endswith("/"):
            raise PublicArtifactPrivacyError(
                f"Non-canonical ZIP directory entry prevents privacy verification: {name}"
            )
        segments = name[:-1].split("/")
    else:
        if name.endswith("/"):
            raise PublicArtifactPrivacyError(
                f"Non-canonical ZIP file entry prevents privacy verification: {name}"
            )
        segments = name.split("/")
    if (
        not segments
        or any(segment in {"", ".", ".."} for segment in segments)
        or PurePosixPath(name).is_absolute()
    ):
        raise PublicArtifactPrivacyError(
            f"Unsafe or non-canonical ZIP entry path prevents privacy verification: {name}"
        )
    canonical = "/".join(segments) + ("/" if info.is_dir() else "")
    if canonical != name:
        raise PublicArtifactPrivacyError(
            f"Unsafe or non-canonical ZIP entry path prevents privacy verification: {name}"
        )
    return name


def validate_zip_members(infos: list[zipfile.ZipInfo]) -> None:
    exact_names: set[str] = set()
    filesystem_names: set[str] = set()
    for info in infos:
        name = canonical_zip_member_name(info)
        filesystem_name = name.rstrip("/").casefold()
        if name in exact_names or filesystem_name in filesystem_names:
            raise PublicArtifactPrivacyError(
                f"Duplicate or colliding ZIP entry prevents privacy verification: {name}"
            )
        exact_names.add(name)
        filesystem_names.add(filesystem_name)
        mode = info.external_attr >> 16
        if info.is_dir():
            continue
        if stat.S_ISLNK(mode):
            raise PublicArtifactPrivacyError(
                f"Public artifact contains a ZIP symlink: {name}"
            )
        if not zip_member_is_regular(info):
            raise PublicArtifactPrivacyError(
                f"Public artifact contains a non-regular ZIP entry: {name}"
            )


def safe_secret(value: object) -> bool:
    if value is None or value is False:
        return True
    if not isinstance(value, str):
        return False
    normalized = value.strip().lower()
    return (
        normalized in SAFE_SECRET_MARKERS
        or re.fullmatch(r"\$\{[A-Z_][A-Z0-9_]*\}", value.strip()) is not None
        or re.fullmatch(r"\$[A-Z_][A-Z0-9_]*", value.strip()) is not None
    )


def sensitive_value_present(value: object) -> bool:
    if value is None or value is False:
        return False
    if isinstance(value, str):
        return bool(value.strip()) and not safe_secret(value)
    if isinstance(value, (list, dict, tuple, set)):
        return bool(value)
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return value != 0
    return True


def iter_directory_entries(root: Path) -> Iterator[ArtifactEntry]:
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            raise PublicArtifactPrivacyError(
                "Public artifact contains a symlink that cannot be privacy-verified: "
                + path.relative_to(root).as_posix()
            )
        if not path.is_file():
            continue
        relative = path.relative_to(root).as_posix()
        if is_text_entry(relative):
            if path.stat().st_size > MAX_TEXT_FILE_BYTES:
                raise PublicArtifactPrivacyError(
                    "Text entry is too large for deterministic privacy verification: "
                    + relative
                )
            with path.open("rb") as file:
                payload = read_bounded_payload(
                    file,
                    limit=MAX_TEXT_FILE_BYTES,
                    name=relative,
                    kind="Text",
                )
            yield ArtifactEntry(name=relative, payload=payload)
        else:
            size = path.stat().st_size
            validate_binary_size(relative, size)
            with path.open("rb") as file:
                payload = read_bounded_payload(
                    file,
                    limit=MAX_BINARY_FILE_BYTES,
                    name=relative,
                    kind="Binary",
                )
            validate_safe_binary(relative, payload)
            yield ArtifactEntry(
                name=relative,
                payload=payload,
                is_binary=True,
            )


def zip_member_is_regular(info: zipfile.ZipInfo) -> bool:
    mode = info.external_attr >> 16
    file_type = stat.S_IFMT(mode)
    return file_type in {0, stat.S_IFREG}


def iter_zip_entries(archive_path: Path) -> Iterator[ArtifactEntry]:
    with zipfile.ZipFile(archive_path) as archive:
        infos = archive.infolist()
        validate_zip_members(infos)
        for info in sorted(infos, key=lambda item: item.filename):
            if info.is_dir():
                continue
            name = info.filename
            if is_text_entry(name):
                if info.file_size > MAX_TEXT_FILE_BYTES:
                    raise PublicArtifactPrivacyError(
                        "Text entry is too large for deterministic privacy "
                        f"verification: {name}"
                    )
                with archive.open(info) as file:
                    payload = read_bounded_payload(
                        file,
                        limit=MAX_TEXT_FILE_BYTES,
                        name=name,
                        kind="Text",
                    )
                yield ArtifactEntry(name=name, payload=payload)
            else:
                validate_binary_size(name, info.file_size)
                with archive.open(info) as file:
                    payload = read_bounded_payload(
                        file,
                        limit=MAX_BINARY_FILE_BYTES,
                        name=name,
                        kind="Binary",
                    )
                validate_safe_binary(name, payload)
                yield ArtifactEntry(
                    name=name,
                    payload=payload,
                    is_binary=True,
                )


def iter_artifact_entries(artifact: Path) -> Iterator[ArtifactEntry]:
    if artifact.is_dir():
        yield from iter_directory_entries(artifact)
        return
    if artifact.is_file() and zipfile.is_zipfile(artifact):
        yield from iter_zip_entries(artifact)
        return
    raise PublicArtifactPrivacyError(
        f"Expected a public artifact directory or ZIP archive: {artifact}"
    )


def add_finding(findings: list[Finding], *, entry: str, kind: str) -> None:
    finding = Finding(entry=entry, kind=kind)
    if finding not in findings:
        findings.append(finding)


def inspect_json(
    value: object,
    *,
    entry: str,
    findings: list[Finding],
    path: tuple[str, ...] = (),
) -> None:
    if isinstance(value, dict):
        keys = set(value)
        normalized_keys = {
            key.replace("_", "").replace("-", "").lower(): key
            for key in keys
            if isinstance(key, str)
        }
        identity_key = normalized_keys.get("identitycode")
        if identity_key is not None and not safe_secret(value[identity_key]):
            add_finding(
                findings,
                entry=entry,
                kind="fingerprint identityCode",
            )
        if (
            "values" in keys
            and isinstance(value["values"], dict)
            and (
                bool(keys & {"capturedAt", "identityCode", "profileID", "profileName"})
                or bool(set(path) & CAPTURE_KEYS)
            )
        ):
            add_finding(findings, entry=entry, kind="raw fingerprint capture values")

        for key, child in value.items():
            normalized = key.replace("_", "").replace("-", "").lower()
            if normalized in SENSITIVE_JSON_KEYS and sensitive_value_present(
                child
            ):
                add_finding(
                    findings,
                    entry=entry,
                    kind="sensitive user, profile, browser or proxy data",
                )
            inspect_json(
                child,
                entry=entry,
                findings=findings,
                path=(*path, key),
            )
    elif isinstance(value, list):
        for index, child in enumerate(value):
            inspect_json(
                child,
                entry=entry,
                findings=findings,
                path=(*path, str(index)),
            )


def inspect_text(
    text: str,
    *,
    entry: str,
    findings: list[Finding],
) -> None:
    source_entry = is_source_entry(entry)
    test_source_entry = source_entry and is_test_source_entry(entry)

    if ABSOLUTE_USER_PATH_RE.search(text):
        add_finding(findings, entry=entry, kind="absolute /Users path")
    if IDENTITY_CODE_RE.search(text):
        add_finding(findings, entry=entry, kind="fingerprint identity code")

    if not test_source_entry:
        for match in PROXY_URI_RE.finditer(text):
            if not safe_secret(match.group(1)) and not safe_secret(match.group(2)):
                add_finding(
                    findings,
                    entry=entry,
                    kind="proxy credentials in URL",
                )
                break

    suffix = PurePosixPath(entry).suffix.lower()
    if not source_entry and suffix in ASSIGNMENT_SUFFIXES:
        for match in PROXY_PASSWORD_ASSIGNMENT_RE.finditer(text):
            if not safe_secret(match.group(1)):
                add_finding(findings, entry=entry, kind="proxy password")
                break


def inspect_binary(entry: ArtifactEntry) -> list[Finding]:
    findings: list[Finding] = []
    # Scan the complete bounded payload. Removing NUL bytes also exposes common
    # UTF-16 metadata without trusting image/PDF metadata parsers.
    candidates = (
        entry.payload.decode("latin-1", errors="ignore"),
        entry.payload.replace(b"\x00", b"").decode(
            "latin-1",
            errors="ignore",
        ),
    )
    for text in candidates:
        if ABSOLUTE_USER_PATH_RE.search(text):
            add_finding(
                findings,
                entry=entry.name,
                kind="absolute /Users path in binary metadata",
            )
        if IDENTITY_CODE_RE.search(text):
            add_finding(
                findings,
                entry=entry.name,
                kind="fingerprint identity code in binary metadata",
            )
        for match in PROXY_URI_RE.finditer(text):
            if not safe_secret(match.group(1)) and not safe_secret(match.group(2)):
                add_finding(
                    findings,
                    entry=entry.name,
                    kind="proxy credentials in binary metadata",
                )
                break
        for match in BINARY_SENSITIVE_ASSIGNMENT_RE.finditer(text):
            if not safe_secret(match.group(1)):
                add_finding(
                    findings,
                    entry=entry.name,
                    kind="credentials in binary metadata",
                )
                break
        for match in PROXY_PASSWORD_ASSIGNMENT_RE.finditer(text):
            if not safe_secret(match.group(1)):
                add_finding(
                    findings,
                    entry=entry.name,
                    kind="proxy password in binary metadata",
                )
                break
    return findings


def inspect_entry(entry: ArtifactEntry) -> list[Finding]:
    if entry.is_binary:
        return inspect_binary(entry)
    if len(entry.payload) > MAX_TEXT_FILE_BYTES:
        raise PublicArtifactPrivacyError(
            f"Text entry is too large for deterministic privacy verification: {entry.name}"
        )
    try:
        text = entry.payload.decode("utf-8")
    except UnicodeDecodeError as error:
        raise PublicArtifactPrivacyError(
            f"Text entry is not valid UTF-8: {entry.name}"
        ) from error

    findings: list[Finding] = []
    inspect_text(text, entry=entry.name, findings=findings)

    suffix = PurePosixPath(entry.name).suffix.lower()
    if suffix == ".json":
        try:
            payload = json.loads(text)
        except json.JSONDecodeError as error:
            raise PublicArtifactPrivacyError(
                "JSON entry is invalid and cannot be privacy-verified: "
                + entry.name
            ) from error
        inspect_json(payload, entry=entry.name, findings=findings)
        if (
            entry.name.endswith(
                "05A-GUI-FINGERPRINT-PUBLIC-ATTESTATION.json"
            )
            or (
                isinstance(payload, dict)
                and payload.get("kind")
                == "neantik-gui-fingerprint-attestation"
            )
        ):
            validate_public_attestation(payload)
    elif suffix == ".jsonl":
        for line_number, line in enumerate(text.splitlines(), start=1):
            if not line.strip():
                continue
            try:
                payload = json.loads(line)
            except json.JSONDecodeError as error:
                raise PublicArtifactPrivacyError(
                    "JSONL entry is invalid and cannot be privacy-verified: "
                    f"{entry.name}:{line_number}"
                ) from error
            inspect_json(payload, entry=entry.name, findings=findings)
    return findings


def expected_public_attestation(
    report: dict[str, object],
    summary: dict[str, object],
    *,
    private_evidence_sha256: str,
    candidate_manifest_sha256: str = "0" * 64,
    release_channel: str = "public-alpha",
) -> dict[str, object]:
    return {
        "schemaVersion": 2,
        "kind": "neantik-gui-fingerprint-attestation",
        "releaseChannel": release_channel,
        "candidateManifestSHA256": candidate_manifest_sha256,
        "createdAt": report.get("createdAt"),
        "managerVersion": report.get("managerVersion"),
        "managerBuild": report.get("managerBuild"),
        "runtimeName": report.get("runtimeName"),
        "runtimeVersion": report.get("runtimeVersion"),
        "runtimeFlavor": report.get("runtimeFlavor"),
        "runtimeCodeSignatureValid": report.get(
            "runtimeCodeSignatureValid"
        ),
        "runtimeExecutableSHA256": report.get(
            "runtimeExecutableSHA256"
        ),
        "runtimeFrameworkSHA256": report.get(
            "runtimeFrameworkSHA256"
        ),
        "privateEvidenceSHA256": private_evidence_sha256,
        "auditSchemaVersion": summary.get("auditSchemaVersion"),
        "identityCatalogVersion": summary.get(
            "identityCatalogVersion"
        ),
        "qualified": summary.get("qualified"),
        "productionQualified": summary.get("productionQualified"),
        "changedCriticalKeys": summary.get("changedCriticalKeys"),
        "unstableRequiredKeys": summary.get("unstableRequiredKeys"),
        "publicAlphaIssues": summary.get("issues"),
        "productionIssues": summary.get("productionIssues"),
    }


def expected_authenticated_public_attestation(
    payload: dict[str, object],
    verified: object,
) -> dict[str, object]:
    return {
        "schemaVersion": 3,
        "kind": "neantik-gui-fingerprint-attestation",
        "releaseChannel": payload["releaseChannel"],
        "candidateManifestSHA256":
            verified.candidate_manifest_sha256,
        "authenticatedEvidenceID":
            verified.authenticated_evidence_id,
        "payloadSHA256": verified.payload_sha256,
        "transportSHA256": verified.transport_sha256,
        "privateEvidenceSHA256": verified.transport_sha256,
        "createdAt": payload["createdAt"],
        "managerVersion": payload["managerVersion"],
        "managerBuild": payload["managerBuild"],
        "runtimeName": payload["runtimeName"],
        "runtimeVersion": payload["runtimeVersion"],
        "runtimeFlavor": payload["runtimeFlavor"],
        "runtimeCodeSignatureValid":
            payload["runtimeCodeSignatureValid"],
        "runtimeExecutableSHA256":
            payload["runtimeExecutableSHA256"],
        "runtimeFrameworkSHA256":
            payload["runtimeFrameworkSHA256"],
        "auditSchemaVersion": payload["auditSchemaVersion"],
        "identityCatalogVersion":
            payload["identityCatalogVersion"],
        "verdict": payload["verdict"],
        "changedCriticalKeys": payload["changedCriticalKeys"],
        "unavailableRequiredKeys":
            payload["unavailableRequiredKeys"],
        "unstableRequiredKeys": payload["unstableRequiredKeys"],
        "publicAlphaQualified":
            payload["publicAlphaQualified"],
        "productionQualified": payload["productionQualified"],
        "limitations": payload["limitations"],
    }


def validate_authenticated_public_attestation(
    payload: object,
) -> dict[str, object]:
    if (
        not isinstance(payload, dict)
        or set(payload) != AUTHENTICATED_PUBLIC_ATTESTATION_KEYS
    ):
        raise PublicArtifactPrivacyError(
            "Authenticated public fingerprint attestation has an invalid "
            "exact key set."
        )
    if payload.get("schemaVersion") != 3:
        raise PublicArtifactPrivacyError(
            "Authenticated public fingerprint attestation schemaVersion "
            "must be 3."
        )
    if payload.get("kind") != "neantik-gui-fingerprint-attestation":
        raise PublicArtifactPrivacyError(
            "Public fingerprint attestation kind is invalid."
        )
    if payload.get("releaseChannel") not in {
        "public-alpha",
        "production",
    }:
        raise PublicArtifactPrivacyError(
            "Public fingerprint attestation release channel is invalid."
        )
    if payload.get("publicAlphaQualified") is not True:
        raise PublicArtifactPrivacyError(
            "Public fingerprint attestation must be public-alpha-qualified."
        )
    if not isinstance(payload.get("productionQualified"), bool):
        raise PublicArtifactPrivacyError(
            "Public fingerprint attestation production verdict must be boolean."
        )
    if (
        payload.get("releaseChannel") == "production"
        and payload.get("productionQualified") is not True
    ):
        raise PublicArtifactPrivacyError(
            "Production attestation must be production-qualified."
        )
    if (
        payload.get("auditSchemaVersion")
        != GUI_VERIFIER.CURRENT_AUDIT_SCHEMA_VERSION
        or payload.get("identityCatalogVersion")
        != GUI_VERIFIER.CURRENT_IDENTITY_CATALOG_VERSION
        or payload.get("runtimeCodeSignatureValid") is not True
        or payload.get("verdict") != "verified"
    ):
        raise PublicArtifactPrivacyError(
            "Authenticated public attestation metadata is invalid."
        )
    for key in (
        "createdAt",
        "managerBuild",
        "managerVersion",
        "runtimeFlavor",
        "runtimeName",
        "runtimeVersion",
    ):
        if not isinstance(payload.get(key), str) or not payload[key].strip():
            raise PublicArtifactPrivacyError(
                f"Public fingerprint attestation {key} is invalid."
            )
    try:
        GUI_VERIFIER.parse_iso8601(payload["createdAt"], "createdAt")
    except GUI_VERIFIER.FingerprintReportError as error:
        raise PublicArtifactPrivacyError(str(error)) from error
    for key in (
        "privateEvidenceSHA256",
        "candidateManifestSHA256",
        "authenticatedEvidenceID",
        "payloadSHA256",
        "transportSHA256",
        "runtimeExecutableSHA256",
        "runtimeFrameworkSHA256",
    ):
        value = payload.get(key)
        if not isinstance(value, str) or re.fullmatch(
            r"[0-9a-f]{64}",
            value,
        ) is None:
            raise PublicArtifactPrivacyError(
                f"Public fingerprint attestation {key} is invalid."
            )
    for key in (
        "changedCriticalKeys",
        "unavailableRequiredKeys",
        "unstableRequiredKeys",
        "limitations",
    ):
        value = payload.get(key)
        if (
            not isinstance(value, list)
            or not all(isinstance(item, str) for item in value)
            or value != sorted(set(value))
        ):
            raise PublicArtifactPrivacyError(
                f"Public fingerprint attestation {key} is invalid."
            )
    return payload


def validate_public_attestation(payload: object) -> dict[str, object]:
    if isinstance(payload, dict) and payload.get("schemaVersion") == 3:
        return validate_authenticated_public_attestation(payload)
    if not isinstance(payload, dict) or set(payload) != PUBLIC_ATTESTATION_KEYS:
        raise PublicArtifactPrivacyError(
            "Public fingerprint attestation has an invalid exact key set."
        )
    if payload.get("schemaVersion") != 2:
        raise PublicArtifactPrivacyError(
            "Public fingerprint attestation schemaVersion must be 2."
        )
    if payload.get("kind") != "neantik-gui-fingerprint-attestation":
        raise PublicArtifactPrivacyError(
            "Public fingerprint attestation kind is invalid."
        )
    if payload.get("qualified") is not True:
        raise PublicArtifactPrivacyError(
            "Public fingerprint attestation must be public-alpha-qualified."
        )
    if payload.get("releaseChannel") not in {
        "public-alpha",
        "production",
    }:
        raise PublicArtifactPrivacyError(
            "Public fingerprint attestation release channel is invalid."
        )
    if payload.get("runtimeCodeSignatureValid") is not True:
        raise PublicArtifactPrivacyError(
            "Public fingerprint attestation must prove a valid runtime signature."
        )
    if not isinstance(payload.get("productionQualified"), bool):
        raise PublicArtifactPrivacyError(
            "Public fingerprint attestation production verdict must be boolean."
        )
    if (
        payload.get("releaseChannel") == "production"
        and payload.get("productionQualified") is not True
    ):
        raise PublicArtifactPrivacyError(
            "Production attestation must be production-qualified."
        )
    if (
        payload.get("auditSchemaVersion")
        != GUI_VERIFIER.CURRENT_AUDIT_SCHEMA_VERSION
        or payload.get("identityCatalogVersion")
        != GUI_VERIFIER.CURRENT_IDENTITY_CATALOG_VERSION
    ):
        raise PublicArtifactPrivacyError(
            "Public fingerprint attestation uses stale audit/catalog metadata."
        )
    for key in (
        "createdAt",
        "managerBuild",
        "managerVersion",
        "runtimeFlavor",
        "runtimeName",
        "runtimeVersion",
    ):
        if not isinstance(payload.get(key), str) or not payload[key].strip():
            raise PublicArtifactPrivacyError(
                f"Public fingerprint attestation {key} is invalid."
            )
    try:
        GUI_VERIFIER.parse_iso8601(payload["createdAt"], "createdAt")
    except GUI_VERIFIER.FingerprintReportError as error:
        raise PublicArtifactPrivacyError(str(error)) from error
    for key in (
        "privateEvidenceSHA256",
        "candidateManifestSHA256",
        "runtimeExecutableSHA256",
        "runtimeFrameworkSHA256",
    ):
        value = payload.get(key)
        if not isinstance(value, str) or re.fullmatch(
            r"[0-9a-f]{64}",
            value,
        ) is None:
            raise PublicArtifactPrivacyError(
                f"Public fingerprint attestation {key} is invalid."
            )
    for key in (
        "changedCriticalKeys",
        "unstableRequiredKeys",
        "publicAlphaIssues",
        "productionIssues",
    ):
        value = payload.get(key)
        if not isinstance(value, list) or not all(
            isinstance(item, str) for item in value
        ):
            raise PublicArtifactPrivacyError(
                f"Public fingerprint attestation {key} is invalid."
            )
    if payload["publicAlphaIssues"]:
        raise PublicArtifactPrivacyError(
            "Qualified public fingerprint attestation contains alpha issues."
        )
    return payload


def verify_evidence_attestation_payload_binding(
    *,
    private_payload: bytes,
    public_payload: object,
    integrated_app: Path,
    release_channel: str = "public-alpha",
    candidate_manifest_sha256: str = "0" * 64,
    candidate_manifest_raw: bytes | None = None,
) -> str:
    if not isinstance(public_payload, dict):
        raise PublicArtifactPrivacyError(
            "Public attestation must be a JSON object."
        )
    validate_public_attestation(public_payload)
    if (
        candidate_manifest_raw is not None
        and public_payload.get("schemaVersion") != 3
    ):
        raise PublicArtifactPrivacyError(
            "Candidate-bound release evidence requires authenticated "
            "schema-8 evidence and a schema-3 public attestation."
        )
    if public_payload.get("releaseChannel") != release_channel:
        raise PublicArtifactPrivacyError(
            "Public attestation release channel does not match the release."
        )
    if (
        public_payload.get("candidateManifestSHA256")
        != candidate_manifest_sha256
    ):
        raise PublicArtifactPrivacyError(
            "Public attestation does not match the immutable candidate manifest."
        )
    if public_payload.get("schemaVersion") == 3:
        if candidate_manifest_raw is None:
            raise PublicArtifactPrivacyError(
                "Authenticated evidence requires the exact candidate manifest."
            )
        try:
            verified = EVIDENCE_SCHEMA.verify_fingerprint_evidence(
                candidate_manifest_raw=candidate_manifest_raw,
                envelope_raw=private_payload,
            )
            payload = EVIDENCE_SCHEMA.load_canonical_json(
                verified.payload,
                maximum_bytes=EVIDENCE_SCHEMA.MAXIMUM_PAYLOAD_BYTES,
                label="Fingerprint evidence payload",
            )
        except EVIDENCE_SCHEMA.FingerprintEvidenceVerificationError as error:
            raise PublicArtifactPrivacyError(
                "Authenticated fingerprint evidence is invalid."
            ) from error
        if payload["releaseChannel"] != release_channel:
            raise PublicArtifactPrivacyError(
                "Authenticated evidence release channel does not match."
            )
        try:
            expected_runtime = (
                GUI_VERIFIER.expected_runtime_evidence_from_app(
                    integrated_app
                )
            )
        except GUI_VERIFIER.FingerprintReportError as error:
            raise PublicArtifactPrivacyError(str(error)) from error
        for payload_key, expected_key in (
            ("managerVersion", "managerVersion"),
            ("managerBuild", "managerBuild"),
            ("runtimeVersion", "runtimeVersion"),
            ("runtimeExecutableSHA256", "runtimeExecutableSHA256"),
            ("runtimeFrameworkSHA256", "runtimeFrameworkSHA256"),
        ):
            if (
                expected_key in expected_runtime
                and payload[payload_key] != expected_runtime[expected_key]
            ):
                raise PublicArtifactPrivacyError(
                    "Authenticated evidence runtime does not match the exact app."
                )
        expected_payload = expected_authenticated_public_attestation(
            payload,
            verified,
        )
        if public_payload != expected_payload:
            raise PublicArtifactPrivacyError(
                "Public attestation fields do not match authenticated evidence."
            )
        return verified.transport_sha256
    expected_sha = hashlib.sha256(private_payload).hexdigest()
    if public_payload.get("privateEvidenceSHA256") != expected_sha:
        raise PublicArtifactPrivacyError(
            "Public attestation does not match the exact private evidence bytes."
        )
    try:
        report = json.loads(private_payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise PublicArtifactPrivacyError(
            "Private fingerprint evidence is not valid UTF-8 JSON."
        ) from error
    if not isinstance(report, dict):
        raise PublicArtifactPrivacyError(
            "Private fingerprint evidence must be a JSON object."
        )
    try:
        expected_runtime = GUI_VERIFIER.expected_runtime_evidence_from_app(
            integrated_app
        )
        summary = GUI_VERIFIER.verification_summary(
            report,
            expected_runtime=expected_runtime,
        )
    except GUI_VERIFIER.FingerprintReportError as error:
        raise PublicArtifactPrivacyError(str(error)) from error
    if release_channel not in {"public-alpha", "production"}:
        raise PublicArtifactPrivacyError(
            "Release channel must be public-alpha or production."
        )
    qualification_issues = GUI_VERIFIER.qualification_issues(
        summary,
        require_production=release_channel == "production",
    )
    if qualification_issues:
        raise PublicArtifactPrivacyError(
            "Private fingerprint evidence is not semantically qualified for "
            f"{release_channel}: "
            + "; ".join(qualification_issues)
        )
    expected_payload = expected_public_attestation(
        report,
        summary,
        private_evidence_sha256=expected_sha,
        candidate_manifest_sha256=candidate_manifest_sha256,
        release_channel=release_channel,
    )
    if public_payload != expected_payload:
        raise PublicArtifactPrivacyError(
            "Public attestation fields do not match private evidence semantics."
        )
    return expected_sha


def verify_evidence_attestation_binding(
    *,
    private_evidence: Path,
    attestation: Path,
    integrated_app: Path,
    release_channel: str = "public-alpha",
    candidate_manifest: Path | None = None,
) -> str:
    try:
        private_payload = private_evidence.read_bytes()
        public_payload = json.loads(attestation.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise PublicArtifactPrivacyError(
            f"Cannot read evidence/attestation binding inputs: {error}"
        ) from error
    candidate_manifest_sha256 = "0" * 64
    candidate_manifest_raw: bytes | None = None
    if candidate_manifest is not None:
        try:
            candidate_manifest_raw = candidate_manifest.read_bytes()
            candidate_manifest_sha256 = hashlib.sha256(
                candidate_manifest_raw
            ).hexdigest()
        except OSError as error:
            raise PublicArtifactPrivacyError(
                f"Cannot read candidate manifest: {error}"
            ) from error
    return verify_evidence_attestation_payload_binding(
        private_payload=private_payload,
        public_payload=public_payload,
        integrated_app=integrated_app,
        release_channel=release_channel,
        candidate_manifest_sha256=candidate_manifest_sha256,
        candidate_manifest_raw=candidate_manifest_raw,
    )


def verify_public_artifact_privacy(*, artifact: Path) -> VerificationResult:
    artifact = artifact.resolve()
    findings: list[Finding] = []
    scanned_entries = 0
    scanned_bytes = 0
    scanned_text_bytes = 0
    for entry in iter_artifact_entries(artifact):
        scanned_entries += 1
        scanned_bytes += len(entry.payload)
        if scanned_bytes > MAX_TOTAL_ARTIFACT_BYTES:
            raise PublicArtifactPrivacyError(
                "Public artifact is too large for deterministic privacy verification"
            )
        if not entry.is_binary:
            scanned_text_bytes += len(entry.payload)
        if scanned_text_bytes > MAX_TOTAL_TEXT_BYTES:
            raise PublicArtifactPrivacyError(
                "Public artifact has too much text for deterministic privacy verification"
            )
        findings.extend(inspect_entry(entry))

    if findings:
        unique = sorted(set(findings), key=lambda item: (item.entry, item.kind))
        summary = "; ".join(
            f"{finding.entry}: {finding.kind}" for finding in unique[:20]
        )
        if len(unique) > 20:
            summary += f"; and {len(unique) - 20} more"
        raise PublicArtifactPrivacyError(
            f"Public artifact contains private evidence ({len(unique)} finding(s)): "
            + summary
        )
    return VerificationResult(
        artifact=artifact,
        scanned_entries=scanned_entries,
        scanned_bytes=scanned_bytes,
    )


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Verify an explicitly selected public directory or ZIP without scanning "
            "local private evidence."
        )
    )
    parser.add_argument("artifact", type=Path)
    parser.add_argument("--private-evidence", type=Path)
    parser.add_argument("--attestation", type=Path)
    parser.add_argument("--integrated-app", type=Path)
    parser.add_argument(
        "--release-channel",
        choices=("public-alpha", "production"),
        default="public-alpha",
    )
    parser.add_argument("--candidate-manifest", type=Path)
    args = parser.parse_args()
    try:
        binding_arguments = (
            args.private_evidence,
            args.attestation,
            args.integrated_app,
        )
        if any(value is not None for value in binding_arguments) and not all(
            value is not None for value in binding_arguments
        ):
            raise PublicArtifactPrivacyError(
                "--private-evidence, --attestation and --integrated-app "
                "must be provided together."
            )
        result = verify_public_artifact_privacy(artifact=args.artifact)
        if (
            args.private_evidence is not None
            and args.attestation is not None
            and args.integrated_app is not None
        ):
            verify_evidence_attestation_binding(
                private_evidence=args.private_evidence,
                attestation=args.attestation,
                integrated_app=args.integrated_app,
                release_channel=args.release_channel,
                candidate_manifest=args.candidate_manifest,
            )
    except (OSError, PublicArtifactPrivacyError, zipfile.BadZipFile) as error:
        print(f"Public artifact privacy verification failed: {error}", file=sys.stderr)
        return 65
    print(
        "Public artifact privacy verified: "
        f"{result.artifact} ({result.scanned_entries} entries, "
        f"{result.scanned_bytes} bytes)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
