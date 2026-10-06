#!/usr/bin/env python3
"""Exact, fail-closed source and binary bindings for Chromium 154.0.8037.98.

This route is intentionally separate from the published 154.0.8037.93
evidence. Source qualification never implies runtime or release qualification.
"""

from __future__ import annotations

import hashlib
import json
import plistlib
import re
from pathlib import Path
from typing import Any

from chromium_15498_source_snapshot import build_snapshot, compact_snapshot


VERSION = "154.0.8037.98"
COMMIT = "b859317bf11f6be47f9b7799ec690a0a42a1fb33"
TREE = "e3eac82f3bb5479e80ab245c514083b5db4fedf3"
PREFIX = "chromium-15498"
HEX64 = re.compile(r"^[0-9a-f]{64}$")
EVIDENCE_NAMES = (
    "device-memory-hotfix.json",
    "external-build-inputs.json",
    "ordered-patch-replay.json",
    "port-compatibility.json",
)
COMPATIBILITY_TARGETS = {
    "restore-upstream-clang-24.patch": "build/toolchain/toolchain.gni",
    "restore-pinned-devtools-esbuild.patch": "third_party/devtools-frontend/src/scripts/build/esbuild.js",
    "bind-safe-browsing-pref-header.patch": "components/safe_browsing/core/common/safe_browsing_prefs.cc",
    "bind-safe-browsing-pref-dep.patch": "components/safe_browsing/core/common/BUILD.gn",
}
HOTFIX_TARGETS = {
    "content/browser/client_hints/client_hints.cc",
    "third_party/blink/renderer/core/loader/frame_fetch_context.cc",
}


class M15498EvidenceError(ValueError):
    pass


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def read_object(path: Path, label: str) -> dict[str, Any]:
    if path.is_symlink() or not path.is_file():
        raise M15498EvidenceError(f"{label} is missing or symlinked")
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise M15498EvidenceError(f"cannot read {label}: {error}") from error
    if not isinstance(document, dict):
        raise M15498EvidenceError(f"{label} must be an object")
    return document


def require_hash(value: object, label: str) -> str:
    if not isinstance(value, str) or not HEX64.fullmatch(value):
        raise M15498EvidenceError(f"{label} must be a SHA-256")
    return value


def reject_local_paths(value: Any, label: str = "evidence") -> None:
    if isinstance(value, dict):
        for key, child in value.items():
            reject_local_paths(child, f"{label}.{key}")
    elif isinstance(value, list):
        for index, child in enumerate(value):
            reject_local_paths(child, f"{label}[{index}]")
    elif isinstance(value, str) and (
        value.startswith(("/", "file:"))
        or "/Users/" in value
        or "/private/tmp/" in value
        or "/var/folders/" in value
    ):
        raise M15498EvidenceError(f"{label} contains a private local path")


def bound_json(runtime: Path, name: str, expected: object) -> dict[str, Any]:
    path = runtime / name
    if sha256_file(path) != require_hash(expected, name):
        raise M15498EvidenceError(f"{name} digest mismatch")
    document = read_object(path, name)
    reject_local_paths(document, name)
    return document


def verify_contract(project_root: Path) -> tuple[dict[str, Any], dict[str, Any]]:
    runtime = project_root.resolve() / "runtime"
    contract = read_object(runtime / f"{PREFIX}-source-contract.json", "M154.98 source contract")
    reject_local_paths(contract, "M154.98 source contract")
    if (contract.get("schemaVersion") != 2
            or contract.get("status") != "source-qualified"
            or contract.get("releaseReady") is not False
            or contract.get("targetChromiumVersion") != VERSION
            or contract.get("targetArchitecture") != "arm64"
            or contract.get("sourceMode") != "official-chromium-owned-macos-port"
            or contract.get("safeBrowsingMode") != 0
            or contract.get("enterpriseCloudContentAnalysis") is not True):
        raise M15498EvidenceError("M154.98 source contract identity or policy mismatch")
    official = contract.get("officialChromiumBase", {})
    if not isinstance(official, dict) or (official.get("commit"), official.get("tree")) != (COMMIT, TREE):
        raise M15498EvidenceError("M154.98 official commit/tree mismatch")
    for key, name in (
        ("sourceSnapshotSHA256", f"{PREFIX}-source-snapshot.json"),
        ("sourceInputManifestSHA256", f"{PREFIX}-source-input-manifest.json"),
        ("toolchainLockSHA256", f"{PREFIX}-toolchain-lock.json"),
        ("securityBaselineSHA256", "security-baseline.json"),
        ("appleDeviceTuplesSHA256", "apple-device-tuples.json"),
        ("rebasePlanSHA256", f"{PREFIX}-rebase-plan.json"),
    ):
        path = runtime / name
        if path.is_symlink() or not path.is_file() or sha256_file(path) != require_hash(contract.get(key), key):
            raise M15498EvidenceError(f"M154.98 {name} digest mismatch")
    snapshot = read_object(runtime / f"{PREFIX}-source-snapshot.json", "M154.98 source snapshot")
    plan = read_object(runtime / f"{PREFIX}-rebase-plan.json", "M154.98 rebase plan")
    previous_plan_path = runtime / "chromium-154-rebase-plan.json"
    previous_plan = read_object(previous_plan_path, "reviewed M154.93 rebase plan")
    if (plan.get("schemaVersion") != 2 or plan.get("status") != "source-replayed"
            or plan.get("releaseReady") is not False
            or plan.get("targetChromiumVersion") != VERSION
            or plan.get("targetArchitecture") != "arm64"
            or plan.get("officialChromiumBase", {}).get("commit") != COMMIT
            or plan.get("officialChromiumBase", {}).get("tree") != TREE
            or plan.get("reviewedPreviousPortPlanSHA256") != sha256_file(previous_plan_path)
            or plan.get("ownedPort", {}).get("sourcePatchVersion") != "154.0.8037.93"
            or plan.get("ownedPort", {}).get("patchGroupCount") != 73
            or plan.get("ownedPort", {}).get("patches") != previous_plan["ownedPort"]["patches"]
            or plan.get("orderedReplay", {}).get("reportSHA256") != sha256_file(runtime / f"{PREFIX}-source-evidence/ordered-patch-replay.json")
            or plan.get("orderedReplay", {}).get("toolSHA256") != sha256_file(project_root / "scripts/replay-chromium-15498.py")
            or plan.get("appleTupleOverlay", {}).get("toolSHA256") != sha256_file(project_root / "scripts/apply-owned-runtime-device-tuples-15498.py")
            or plan.get("deviceMemoryHotfix", {}).get("toolSHA256") != sha256_file(project_root / "scripts/apply-device-memory-hotfix-15498.py")
            or plan.get("compatibilityOverlay", {}).get("reportSHA256") != sha256_file(runtime / f"{PREFIX}-source-evidence/port-compatibility.json")
            or plan.get("buildPolicy", {}).get("argsGNSHA256") != contract.get("buildArgsSHA256")
            or plan.get("buildPolicy", {}).get("toolchainLockSHA256") != contract.get("toolchainLockSHA256")):
        raise M15498EvidenceError("M154.98 rebase plan differs from reviewed source inputs")
    for key in ("upstreamCommonOverlay", "upstreamMacPackaging"):
        expected = previous_plan[key]
        actual = plan.get(key, {})
        if not isinstance(actual, dict) or any(actual.get(field) != expected[field] for field in ("repository", "commit", "tree", "seriesSHA256", "patchCount")):
            raise M15498EvidenceError(f"M154.98 {key} differs from pinned upstream input")
    if (snapshot.get("schemaVersion") != 2
            or snapshot.get("recordType") != "chromium-source-snapshot"
            or snapshot.get("targetChromiumVersion") != VERSION
            or snapshot.get("officialChromiumBase") != {"commit": COMMIT, "tree": TREE}
            or snapshot.get("releaseReady") is not False
            or not isinstance(snapshot.get("sourceFileCount"), int)
            or snapshot["sourceFileCount"] < 1_000_000
            or not isinstance(snapshot.get("deletedPathCount"), int)
            or snapshot["deletedPathCount"] < 1
            or not all(HEX64.fullmatch(str(snapshot.get(key, ""))) for key in ("entriesSHA256", "deletedPathsSHA256"))):
        raise M15498EvidenceError("M154.98 source snapshot identity mismatch")
    args = snapshot.get("argsGN", {})
    if (not isinstance(args, dict)
            or args.get("relativePath") != "out/NeAntikM154Qualified20261006/args.gn"
            or args.get("sha256") != require_hash(contract.get("buildArgsSHA256"), "buildArgsSHA256")):
        raise M15498EvidenceError("M154.98 build args are not bound to the snapshot")
    manifest = read_object(runtime / f"{PREFIX}-source-input-manifest.json", "M154.98 input manifest")
    reject_local_paths(manifest, "M154.98 input manifest")
    if (manifest.get("schemaVersion") != 1
            or manifest.get("chromiumVersion") != VERSION
            or manifest.get("status") != "source-reconstructed"
            or manifest.get("sourceInputsReady") is not True
            or manifest.get("releaseReady") is not False
            or manifest.get("sourceSnapshotSHA256") != contract["sourceSnapshotSHA256"]
            or manifest.get("buildArgsSHA256") != contract["buildArgsSHA256"]):
        raise M15498EvidenceError("M154.98 source input manifest mismatch")
    evidence = manifest.get("evidence")
    if (not isinstance(evidence, list)
            or [item.get("path") for item in evidence if isinstance(item, dict)] != list(EVIDENCE_NAMES)
            or len(evidence) != len(EVIDENCE_NAMES)):
        raise M15498EvidenceError("M154.98 evidence set differs from the reviewed set")
    evidence_root = runtime / f"{PREFIX}-source-evidence"
    if evidence_root.is_symlink() or not evidence_root.is_dir():
        raise M15498EvidenceError("M154.98 evidence directory is unsafe")
    actual_names = sorted(path.name for path in evidence_root.iterdir() if path.is_file())
    qualification_name = "coherent-apple-device-tuples-runtime-qualification.json"
    if actual_names not in (sorted(EVIDENCE_NAMES), sorted((*EVIDENCE_NAMES, qualification_name))):
        raise M15498EvidenceError("M154.98 evidence directory has missing or extra files")
    for item in evidence:
        name = item["path"]
        bound_json(evidence_root, name, item.get("sha256"))
    replay = read_object(evidence_root / "ordered-patch-replay.json", "M154.98 patch replay")
    if (replay.get("targetVersion") != VERSION or replay.get("sourceCommit") != COMMIT
            or replay.get("sourceTree") != TREE or replay.get("replayComplete") is not True
            or replay.get("releaseReady") is not False or replay.get("targetCount") != 798
            or len(replay.get("applied", [])) != 202
            or replay.get("rejectedArtifactsInTargets") != []):
        raise M15498EvidenceError("M154.98 patch replay is incomplete")
    groups = replay["applied"]
    labels = [item.get("label") for item in groups if isinstance(item, dict)]
    if (len(labels) != 202 or len(set(labels)) != 202
            or sum(label.startswith("common:") for label in labels) != 109
            or sum(label.startswith("mac:") for label in labels) != 20
            or sum(label.startswith("owned:") for label in labels) != 73
            or not all(HEX64.fullmatch(str(item.get("patchSHA256", ""))) for item in groups)):
        raise M15498EvidenceError("M154.98 patch group identity is incomplete")
    for key in ("inputTargetDigest", "postimageTargetDigest", "pruningSourceSHA256", "presentPruningSHA256"):
        require_hash(replay.get(key), f"M154.98 replay {key}")
    owned_patches = plan["ownedPort"]["patches"]
    owned_replay = groups[129:]
    for item, recorded in zip(owned_patches, owned_replay, strict=True):
        path = runtime / "nevision-patches/ports/chromium-154.0.8037.93" / item["path"]
        if (path.is_symlink() or not path.is_file()
                or sha256_file(path) != item["sha256"]
                or recorded.get("label") != f"owned:{item['order']}:{item['id']}"
                or recorded.get("patchSHA256") != item["sha256"]):
            raise M15498EvidenceError("M154.98 owned patch bytes or replay order differ")
    hotfix = read_object(evidence_root / "device-memory-hotfix.json", "M154.98 Device Memory hotfix")
    if (hotfix.get("targetVersion") != VERSION or hotfix.get("releaseReady") is not False
            or len(hotfix.get("files", [])) != 2
            or {item.get("sourcePath") for item in hotfix["files"] if isinstance(item, dict)} != HOTFIX_TARGETS):
        raise M15498EvidenceError("M154.98 Device Memory source fix is incomplete")
    external = read_object(evidence_root / "external-build-inputs.json", "M154.98 external inputs")
    if (external.get("schemaVersion") != 1
            or external.get("targetVersion") != VERSION
            or external.get("status") != "verified-external-build-inputs"
            or external.get("releaseReady") is not False
            or external.get("dsymutil", {}).get("objectSHA1") != "d72733d9365a8c75966b524a739bccb23151a021"
            or external.get("dsymutil", {}).get("downloadSHA256") != external.get("dsymutil", {}).get("installedSHA256")
            or external.get("webuiNodeModules", {}).get("archiveSHA256") != "a298af5fafd358179d6aec9a42f667902dbcdb03a42ee4a87a1bff83515e96b9"
            or external.get("devtoolsEsbuild", {}).get("packageVersion") != "0.25.1"
            or external.get("devtoolsEsbuild", {}).get("archiveSHA512Integrity") != "sha512-5hEZKPf+nQjYoSr/elb62U19/l1mZDdqidGfmFutVUjjUZrOazAtwK+Kr+3y0C/oeJfLlxo9fXb1w7L+P7E4FQ=="
            or external.get("undiciTypes", {}).get("packageVersion") != "7.18.2"
            or external.get("undiciTypes", {}).get("archiveSHA512Integrity") != "sha512-AsuCzffGHJybSaRrmr5eHr81mwJU3kjw6M+uprWvCXiNeN9SOGwQ3Jn8jb8m3Z6izVgknn1R0FTCEAP2QrLY/w=="
            or external.get("undiciTypes", {}).get("archiveSHA256") != "4d92799b0e619468a30f70eff033c1a27e713134a4ff353e1a6794f67e425497"
            or external.get("undiciTypes", {}).get("recoveredDeclarationCount") != 43
            or external.get("clang", {}).get("version") != "24.0.0"):
        raise M15498EvidenceError("M154.98 external inputs differ from pinned .98 inputs")
    compatibility = read_object(evidence_root / "port-compatibility.json", "M154.98 port compatibility")
    if (compatibility.get("targetVersion") != VERSION
            or compatibility.get("releaseReady") is not False
            or len(compatibility.get("patches", [])) != len(COMPATIBILITY_TARGETS)
            or {item.get("name") for item in compatibility["patches"] if isinstance(item, dict)} != set(COMPATIBILITY_TARGETS)):
        raise M15498EvidenceError("M154.98 port compatibility is incomplete")
    if plan.get("compatibilityOverlay", {}).get("patches") != compatibility["patches"]:
        raise M15498EvidenceError("M154.98 compatibility plan differs from evidence")
    for item in compatibility["patches"]:
        name = item.get("name")
        if name not in COMPATIBILITY_TARGETS or item.get("sourcePath") != COMPATIBILITY_TARGETS[name]:
            raise M15498EvidenceError("M154.98 compatibility patch name is unknown")
        path = runtime / "nevision-patches/ports/chromium-154.0.8037.98/patches" / name
        if path.is_symlink() or not path.is_file() or sha256_file(path) != require_hash(item.get("sha256"), name):
            raise M15498EvidenceError("M154.98 compatibility patch digest mismatch")
    return contract, snapshot


def verify_candidate_document(
    document: dict[str, Any], *, project_root: Path, source_root: Path | None = None
) -> None:
    runtime = project_root.resolve() / "runtime"
    canonical = read_object(runtime / f"{PREFIX}-port-candidate.json", "M154.98 candidate")
    if document != canonical:
        raise M15498EvidenceError("M154.98 candidate differs from canonical evidence")
    contract, snapshot = verify_contract(project_root)
    if (document.get("schemaVersion") != 1
            or document.get("status") != "candidate-bound"
            or document.get("releaseReady") is not False
            or document.get("targetChromiumVersion") != VERSION
            or document.get("targetArchitecture") != "arm64"
            or document.get("sourceContractSHA256") != sha256_file(runtime / f"{PREFIX}-source-contract.json")
            or document.get("sourceInputManifestSHA256") != contract["sourceInputManifestSHA256"]
            or document.get("sourceSnapshotSHA256") != contract["sourceSnapshotSHA256"]):
        raise M15498EvidenceError("M154.98 candidate source binding mismatch")
    binding = document.get("binaryBinding", {})
    if not isinstance(binding, dict) or (binding.get("status"), binding.get("sourceVersion"), binding.get("architecture")) != ("bound-to-built-candidate", VERSION, "arm64"):
        raise M15498EvidenceError("M154.98 candidate binary binding is absent")
    for key in ("argsGNSHA256", "candidateExecutableSHA256", "candidateFrameworkSHA256"):
        require_hash(binding.get(key), key)
    if binding["argsGNSHA256"] != contract["buildArgsSHA256"]:
        raise M15498EvidenceError("M154.98 binary was built with different args")
    reject_local_paths(document, "M154.98 candidate")
    if source_root is not None:
        relative = snapshot["argsGN"]["relativePath"]
        current = compact_snapshot(build_snapshot(source_root, source_root / relative))
        if current != snapshot:
            raise M15498EvidenceError("M154.98 live source differs from frozen snapshot")
        evidence_root = runtime / f"{PREFIX}-source-evidence"
        external = read_object(evidence_root / "external-build-inputs.json", "M154.98 external inputs")
        live_inputs = (
            ("tools/clang/dsymutil/bin/dsymutil", external["dsymutil"]["installedSHA256"]),
            ("third_party/node/node_modules/lit-html/directives/repeat.d.ts", external["webuiNodeModules"]["repeatDeclarationSHA256"]),
            ("third_party/node/node_modules/undici-types/index.d.ts", external["undiciTypes"]["indexDeclarationSHA256"]),
            ("third_party/devtools-frontend/src/node_modules/@esbuild/darwin-arm64/bin/esbuild", external["devtoolsEsbuild"]["binarySHA256"]),
            ("third_party/devtools-frontend/src/third_party/esbuild/esbuild", external["devtoolsEsbuild"]["pinnedCIPDBinarySHA256"]),
            ("third_party/llvm-build/Release+Asserts/bin/clang", external["clang"]["binarySHA256"]),
        )
        for name, expected in live_inputs:
            path = source_root / name
            if path.is_symlink() or not path.is_file() or sha256_file(path) != require_hash(expected, name):
                raise M15498EvidenceError(f"M154.98 live external input {name} differs")
        compatibility = read_object(evidence_root / "port-compatibility.json", "M154.98 compatibility")
        for item in compatibility["patches"]:
            path = source_root / item["sourcePath"]
            if path.is_symlink() or not path.is_file() or sha256_file(path) != require_hash(item.get("postimageSHA256"), item["sourcePath"]):
                raise M15498EvidenceError("M154.98 live compatibility postimage differs")
        hotfix = read_object(evidence_root / "device-memory-hotfix.json", "M154.98 hotfix")
        for item in hotfix["files"]:
            path = source_root / item["sourcePath"]
            if path.is_symlink() or not path.is_file() or sha256_file(path) != require_hash(item.get("postimageSHA256"), item["sourcePath"]):
                raise M15498EvidenceError("M154.98 live Device Memory postimage differs")


def verify_unsigned_binary_binding(app: Path, args_gn: Path, document: dict[str, Any]) -> None:
    if app.is_symlink() or not app.is_dir():
        raise M15498EvidenceError("M154.98 unsigned app is missing or symlinked")
    app = app.resolve()
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    name = info.get("CFBundleExecutable")
    if (not isinstance(name, str) or not name or "/" in name
            or info.get("CFBundleShortVersionString") != VERSION):
        raise M15498EvidenceError("M154.98 unsigned app identity mismatch")
    binding = document.get("binaryBinding", {})
    paths = (
        (app / "Contents/MacOS" / name, "candidateExecutableSHA256"),
        (app / "Contents/Frameworks/NeAntik Browser Framework.framework/Versions" / VERSION
         / "NeAntik Browser Framework", "candidateFrameworkSHA256"),
        (args_gn, "argsGNSHA256"),
    )
    for path, key in paths:
        if path.is_symlink() or not path.is_file() or sha256_file(path) != require_hash(binding.get(key), key):
            raise M15498EvidenceError(f"M154.98 unsigned {key} mismatch")
        if key != "argsGNSHA256" and not path.resolve().is_relative_to(app):
            raise M15498EvidenceError("M154.98 unsigned binary escapes its app")


def verify_candidate_lock(
    lock: dict[str, Any], *, provenance: dict[str, Any], project_root: Path
) -> None:
    runtime = project_root.resolve() / "runtime"
    canonical = read_object(runtime / "fingerprint-chromium-15498.lock.json", "M154.98 candidate lock")
    if lock != canonical:
        raise M15498EvidenceError("M154.98 lock differs from canonical candidate")
    verify_candidate_document(provenance, project_root=project_root)
    if (lock.get("schemaVersion") != 4 or lock.get("status") != "source-qualified"
            or lock.get("releaseReady") is not False
            or lock.get("targetArchitecture") != "arm64"
            or lock.get("fingerprintChromium", {}).get("chromiumVersion") != VERSION
            or lock.get("fingerprintChromium", {}).get("commit") != COMMIT
            or lock.get("fingerprintChromium", {}).get("tree") != TREE
            or lock.get("sourceContractSHA256") != sha256_file(runtime / f"{PREFIX}-source-contract.json")
            or lock.get("sourceProvenanceSHA256") != sha256_file(runtime / f"{PREFIX}-port-candidate.json")):
        raise M15498EvidenceError("M154.98 candidate lock binding mismatch")
    verify_tuple_runtime_qualification(lock, provenance, runtime)
    reject_local_paths(lock, "M154.98 candidate lock")


def verify_tuple_runtime_qualification(
    lock: dict[str, Any], candidate: dict[str, Any], runtime: Path
) -> None:
    verification = lock.get("verification")
    if not isinstance(verification, dict) or verification.get("coherentAppleDeviceTuples") != "verified":
        return
    relative = f"runtime/{PREFIX}-source-evidence/coherent-apple-device-tuples-runtime-qualification.json"
    if verification.get("coherentAppleDeviceTuplesEvidence") != relative:
        raise M15498EvidenceError("M154.98 verified tuple evidence path is not pinned")
    path = runtime.parent / relative
    evidence = read_object(path, "M154.98 verified tuple evidence")
    if verification.get("coherentAppleDeviceTuplesEvidenceSHA256") != sha256_file(path):
        raise M15498EvidenceError("M154.98 verified tuple evidence digest mismatch")
    reject_local_paths(evidence, "M154.98 verified tuple evidence")
    memory = evidence.get("deviceMemory")
    if (evidence.get("schemaVersion") != 1 or evidence.get("status") != "verified"
            or evidence.get("chromiumVersion") != VERSION
            or evidence.get("guiProductionQualified") is not True
            or evidence.get("releaseReady") is not False
            or not isinstance(memory, dict) or memory.get("coherent") is not True):
        raise M15498EvidenceError("M154.98 tuple runtime qualification is incomplete")
    if evidence.get("sourceCandidateSHA256") != sha256_file(runtime / f"{PREFIX}-port-candidate.json"):
        raise M15498EvidenceError("M154.98 tuple evidence is bound to another source candidate")
    if evidence.get("tupleCatalogSHA256") != sha256_file(runtime / "apple-device-tuples.json"):
        raise M15498EvidenceError("M154.98 tuple evidence uses another device catalog")
    binding = candidate.get("binaryBinding", {})
    if evidence.get("unsignedFrameworkSHA256") != binding.get("candidateFrameworkSHA256"):
        raise M15498EvidenceError("M154.98 tuple evidence uses another unsigned framework")
    js = memory.get("js")
    if not isinstance(js, (int, float)) or isinstance(js, bool) or js <= 0:
        raise M15498EvidenceError("M154.98 Device Memory JS evidence is invalid")
    for kind in ("navigation", "subresource"):
        headers = memory.get(kind)
        if not isinstance(headers, dict) or any(headers.get(name) != str(js) for name in ("modern", "legacy")):
            raise M15498EvidenceError(f"M154.98 {kind} Device Memory evidence is incoherent")
    for key in (
        "signedRuntimeExecutableSHA256", "signedRuntimeFrameworkSHA256",
        "candidateManifestSHA256", "authenticatedGUIEnvelopeSHA256",
        "publicSafeGUISummarySHA256",
    ):
        require_hash(evidence.get(key), key)
