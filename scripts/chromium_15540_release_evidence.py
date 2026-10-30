#!/usr/bin/env python3
"""Exact M155.40 source/build bindings; no runtime qualification implied.

M154 contracts remain separate. Unknown M155 versions cannot use this route.
"""
from __future__ import annotations
import hashlib
import json
import plistlib
import re
from pathlib import Path
from runtime_historical_baseline import bound_baseline_path
from typing import Any
from chromium_15540_source_snapshot import build_snapshot, compact_snapshot

VERSION = "155.0.8059.40"
COMMIT = "cfaadc5a132d78e1828635aa8405a499f3e14864"
TREE = "6ff797d22a0943b4a56a38dc6e27a87f158246d3"
PREFIX = "chromium-15540"
HEX64 = re.compile(r"^[0-9a-f]{64}$")
EVIDENCE_NAMES = (
    "ordered-patch-replay.json", "reviewed-source-overlay.json", "overlay-applied.json",
    "partial-port-decisions.json", "upstream-superseded-decisions.json", "pruning.json",
    "domain-substitution.json", "domain-substitution-inventory.json", "pinned-build-inputs.json", "generated-deps-hooks.json",
    "port-compatibility.json", "deps-revisions.json",
)
class M15540EvidenceError(ValueError):
    pass

def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def read_object(path: Path, label: str) -> dict[str, Any]:
    if path.is_symlink() or not path.is_file():
        raise M15540EvidenceError(f"{label} is missing or symlinked")
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise M15540EvidenceError(f"cannot read {label}: {error}") from error
    if not isinstance(document, dict):
        raise M15540EvidenceError(f"{label} must be an object")
    return document


def require_hash(value: object, label: str) -> str:
    if not isinstance(value, str) or not HEX64.fullmatch(value):
        raise M15540EvidenceError(f"{label} must be a SHA-256")
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
        raise M15540EvidenceError(f"{label} contains a private local path")


def bound_json(runtime: Path, name: str, expected: object) -> dict[str, Any]:
    path = runtime / name
    if sha256_file(path) != require_hash(expected, name):
        raise M15540EvidenceError(f"{name} digest mismatch")
    document = read_object(path, name)
    reject_local_paths(document, name)
    return document


def safe_relative_regular(root: Path, name: str) -> Path:
    if not isinstance(name, str) or not name or name != "/".join(name.split("/")) or any(p in {"", ".", ".."} for p in name.split("/")) or name.startswith("/"):
        raise M15540EvidenceError("unsafe source input path")
    target = root / name
    if any(p.is_symlink() for p in (target, *target.parents) if p == root or p.is_relative_to(root)):
        raise M15540EvidenceError("source input crosses symlink")
    if not target.is_file() or not target.resolve().is_relative_to(root.resolve()):
        raise M15540EvidenceError("source input is missing or outside root")
    return target


def final_overlay_postimages(runtime: Path) -> dict[str, str]:
    evidence = runtime / f"{PREFIX}-source-evidence"
    overlay = read_object(evidence / "reviewed-source-overlay.json", "M155.40 overlay")
    domains = json.loads(safe_relative_regular(evidence, "domain-substitution-inventory.json").read_text())
    domain_report = read_object(evidence / "domain-substitution.json", "M155.40 domains")
    if sha256_file(evidence / "domain-substitution-inventory.json") != domain_report.get("inventorySHA256"):
        raise M15540EvidenceError("M155.40 domain inventory binding mismatch")
    if not isinstance(domains, list) or len(domains) != domain_report.get("listedCount"):
        raise M15540EvidenceError("M155.40 domain inventory incomplete")
    mapping = {i["path"]: i for i in domains}
    if len(mapping) != len(domains):
        raise M15540EvidenceError("duplicate domain inventory path")
    result = {}
    for item in overlay["files"]:
        name, post = item["path"], require_hash(item["postimageSHA256"], "overlay postimage")
        if name in mapping:
            domain = mapping[name]
            if domain["preimageSHA256"] != post:
                raise M15540EvidenceError("domain stage does not follow reviewed overlay")
            post = require_hash(domain["postimageSHA256"], "domain postimage")
        result[name] = post
    compatibility = read_object(evidence / "port-compatibility.json", "M155.40 compatibility")
    for item in compatibility["files"]:
        if item.get("patchPath") and sha256_file(safe_relative_regular(runtime.parent, item["patchPath"])) != item.get("patchSHA256"):
            raise M15540EvidenceError("M155.40 compatibility patch binding mismatch")
        result[item["path"]] = require_hash(item["postimageSHA256"], "compatibility postimage")
    hooks = read_object(evidence / "generated-deps-hooks.json", "M155.40 generated hooks")
    for item in hooks["files"]:
        result[item["path"]] = require_hash(item["sha256"], "generated hook")
    return result


def verify_contract(project_root: Path) -> tuple[dict[str, Any], dict[str, Any]]:
    runtime = project_root.resolve() / "runtime"
    contract = read_object(runtime / f"{PREFIX}-source-contract.json", "M155.40 source contract")
    reject_local_paths(contract)
    if (contract.get("schemaVersion") != 2 or contract.get("status") != "source-qualified"
            or contract.get("releaseReady") is not False or contract.get("targetChromiumVersion") != VERSION
            or contract.get("targetArchitecture") != "arm64"
            or contract.get("sourceMode") != "official-chromium-owned-macos-port"
            or contract.get("safeBrowsingMode") != 0 or contract.get("enterpriseCloudContentAnalysis") is not True
            or contract.get("officialChromiumBase") != {"commit": COMMIT, "tree": TREE}):
        raise M15540EvidenceError("M155.40 source identity or policy mismatch")
    bindings = (
        ("sourceSnapshotSHA256", f"{PREFIX}-source-snapshot.json"),
        ("sourceInputManifestSHA256", f"{PREFIX}-source-input-manifest.json"),
        ("toolchainLockSHA256", f"{PREFIX}-toolchain-lock.json"),
        ("securityBaselineSHA256", "security-baseline.json"),
        ("appleDeviceTuplesSHA256", "apple-device-tuples.json"),
        ("rebasePlanSHA256", f"{PREFIX}-rebase-plan.json"),
    )
    for field, name in bindings:
        path = runtime / name
        if field == "securityBaselineSHA256":
            path = bound_baseline_path(runtime, contract.get(field))
        if path.is_symlink() or not path.is_file() or sha256_file(path) != require_hash(contract.get(field), field):
            raise M15540EvidenceError(f"M155.40 {name} binding mismatch")
    plan = read_object(runtime / f"{PREFIX}-rebase-plan.json", "M155.40 plan")
    reject_local_paths(plan)
    if (plan.get("schemaVersion") != 2 or plan.get("status") != "source-replayed"
            or plan.get("releaseReady") is not False or plan.get("targetChromiumVersion") != VERSION
            or plan.get("officialChromiumBase", {}).get("commit") != COMMIT
            or plan.get("officialChromiumBase", {}).get("tree") != TREE
            or plan.get("buildPolicy", {}).get("argsGNSHA256") != contract.get("buildArgsSHA256")
            or plan.get("buildPolicy", {}).get("toolchainLockSHA256") != contract.get("toolchainLockSHA256")):
        raise M15540EvidenceError("M155.40 rebase plan binding mismatch")
    for key, identity in (
        ("upstreamCommonOverlay", ("37085e47cf580c815a30402917d350ce97399ded", "e0754007a836944e1365c17ce502907594af12f6", 109)),
        ("upstreamMacPackaging", ("f7ba75f94442abda7ac3ea81790c217f8636d3ba", "019bd2588e47f70b301e09e5475b1b1abd82ad35", 20)),
    ):
        item = plan.get(key, {})
        if (item.get("commit"), item.get("tree"), item.get("patchCount")) != identity:
            raise M15540EvidenceError("M155.40 upstream port input mismatch")
    for item in plan.get("reviewedTools", []):
        name = item.get("path", "")
        if not name.startswith("scripts/") or ".." in Path(name).parts:
            raise M15540EvidenceError("unsafe reviewed tool path")
        if sha256_file(safe_relative_regular(project_root, name)) != require_hash(item.get("sha256"), name):
            raise M15540EvidenceError("M155.40 reviewed source tool changed")
    if not plan.get("reviewedTools"):
        raise M15540EvidenceError("M155.40 reviewed tools are missing")
    snapshot = read_object(runtime / f"{PREFIX}-source-snapshot.json", "M155.40 snapshot")
    prebuild_hash = require_hash(plan.get("buildPolicy", {}).get("sourceInputSnapshotSHA256"), "pre-build input snapshot")
    if prebuild_hash != contract.get("sourceSnapshotSHA256"):
        raise M15540EvidenceError("M155.40 frozen source differs from reviewed pre-build inventory")
    reject_local_paths(snapshot)
    if (snapshot.get("schemaVersion") != 2 or snapshot.get("recordType") != "chromium-source-snapshot"
            or snapshot.get("targetChromiumVersion") != VERSION or snapshot.get("releaseReady") is not False
            or snapshot.get("officialChromiumBase") != {"commit": COMMIT, "tree": TREE}
            or snapshot.get("sourceFileCount", 0) < 1_000_000 or snapshot.get("deletedPathCount", 0) < 1
            or snapshot.get("argsGN", {}).get("relativePath") != "out/NeAntikM155Qualified20261008/args.gn"
            or snapshot.get("argsGN", {}).get("sha256") != contract.get("buildArgsSHA256")):
        raise M15540EvidenceError("M155.40 source snapshot identity mismatch")
    for field in ("entriesSHA256", "deletedPathsSHA256"):
        require_hash(snapshot.get(field), field)
    manifest = read_object(runtime / f"{PREFIX}-source-input-manifest.json", "M155.40 input manifest")
    reject_local_paths(manifest)
    if (manifest.get("schemaVersion") != 1 or manifest.get("chromiumVersion") != VERSION
            or manifest.get("status") != "source-reconstructed" or manifest.get("sourceInputsReady") is not True
            or manifest.get("releaseReady") is not False
            or manifest.get("sourceSnapshotSHA256") != contract["sourceSnapshotSHA256"]
            or manifest.get("sourceInputSnapshotSHA256") != prebuild_hash
            or manifest.get("buildArgsSHA256") != contract["buildArgsSHA256"]):
        raise M15540EvidenceError("M155.40 manifest identity mismatch")
    items = manifest.get("evidence", [])
    if [item.get("path") for item in items] != list(EVIDENCE_NAMES):
        raise M15540EvidenceError("M155.40 evidence set mismatch")
    evidence_root = runtime / f"{PREFIX}-source-evidence"
    expected_names = set(EVIDENCE_NAMES)
    actual_names = {p.name for p in evidence_root.iterdir()} if evidence_root.is_dir() else set()
    if evidence_root.is_symlink() or actual_names not in (expected_names, expected_names | {"coherent-apple-device-tuples-runtime-qualification.json"}):
        raise M15540EvidenceError("M155.40 evidence directory has missing or extra inputs")
    documents = {}
    for item in items:
        path = safe_relative_regular(evidence_root, item["path"])
        if sha256_file(path) != require_hash(item["sha256"], item["path"]):
            raise M15540EvidenceError("M155.40 evidence digest mismatch")
        document = json.loads(path.read_text())
        reject_local_paths(document)
        if item["path"] == "domain-substitution-inventory.json":
            if not isinstance(document, list):
                raise M15540EvidenceError("domain inventory must be an array")
        elif item["path"] not in {"partial-port-decisions.json", "upstream-superseded-decisions.json"}:
            if not isinstance(document, dict) or document.get("targetVersion") != VERSION or document.get("releaseReady") is not False:
                raise M15540EvidenceError("mixed or incomplete runtime evidence")
        documents[item["path"]] = document
    replay = documents["ordered-patch-replay.json"]
    records = replay.get("records", [])
    labels = [item.get("label", "") for item in records]
    if (replay.get("sourceCommit") != COMMIT or replay.get("replayComplete") is not True
            or len(records) != 202 or len(set(labels)) != 202
            or sum(n.startswith("common:") for n in labels) != 109
            or sum(n.startswith("macos:") for n in labels) != 20
            or sum(n.startswith("owned:") for n in labels) != 73):
        raise M15540EvidenceError("M155.40 ordered replay is incomplete")
    inputs = plan.get("orderedPatchInputs", [])
    if len(inputs) != 202:
        raise M15540EvidenceError("M155.40 patch input matrix incomplete")
    for record, item in zip(records, inputs, strict=True):
        if (record.get("label"), record.get("patchSHA256"), record.get("originalSHA256")) != (item.get("label"), item.get("patchSHA256"), item.get("originalSHA256")):
            raise M15540EvidenceError("M155.40 replay order or patch bytes mismatch")
        if item.get("localPatchPath"):
            name = item["localPatchPath"]
            if not name.startswith("runtime/nevision-patches/ports/") or ".." in Path(name).parts:
                raise M15540EvidenceError("unsafe M155 patch path")
            if sha256_file(safe_relative_regular(project_root, name)) != item["patchSHA256"]:
                raise M15540EvidenceError("M155.40 local patch changed")
        for field in ("patchSHA256", "originalSHA256"):
            require_hash(item.get(field), field)
    overlay = documents["reviewed-source-overlay.json"]
    if overlay.get("sourceCommit") != COMMIT or overlay.get("sourceTree") != TREE or len(overlay.get("files", [])) != 14:
        raise M15540EvidenceError("M155.40 coherent device/memory overlay incomplete")
    if overlay.get("orderedReplaySHA256") != sha256_file(evidence_root / "ordered-patch-replay.json"):
        raise M15540EvidenceError("M155.40 overlay belongs to another replay")
    if documents["overlay-applied.json"].get("overlayLockSHA256") != sha256_file(evidence_root / "reviewed-source-overlay.json"):
        raise M15540EvidenceError("M155.40 overlay receipt mismatch")
    for item in overlay["patches"] + overlay["tupleRendererInputs"]:
        if sha256_file(safe_relative_regular(project_root, item["path"])) != item["sha256"]:
            raise M15540EvidenceError("M155.40 tuple or memory fix input changed")
    expected_overlay_paths = {
        "components/ungoogled/neantik_apple_device_tuples.h", "components/embedder_support/user_agent_utils.cc", "components/embedder_support/BUILD.gn",
        "third_party/blink/renderer/core/frame/navigator_concurrent_hardware.cc", "third_party/blink/renderer/core/frame/navigator_device_memory.cc",
        "third_party/blink/renderer/core/frame/screen.cc", "third_party/blink/renderer/core/frame/local_dom_window.cc",
        "third_party/blink/renderer/modules/webgl/webgl_rendering_context_base.cc", "content/browser/client_hints/client_hints.cc",
        "third_party/blink/renderer/core/loader/frame_fetch_context.cc", "third_party/blink/renderer/core/css/media_values.cc",
        "components/safe_browsing/core/common/safe_browsing_prefs.cc", "components/safe_browsing/core/common/BUILD.gn", "build/toolchain/toolchain.gni",
    }
    if (set(i["path"] for i in overlay["files"]) != expected_overlay_paths
            or documents["overlay-applied.json"].get("files") != overlay["files"]
            or overlay.get("tupleCatalogSHA256") != contract["appleDeviceTuplesSHA256"]):
        raise M15540EvidenceError("M155.40 coherent overlay identity mismatch")
    final_overlay_postimages(runtime)
    pruning = documents["pruning.json"]
    if (pruning.get("keepContingentPaths") is not True or pruning.get("removedCount") != 13832
            or {i.get("path") for i in pruning.get("protectedRestoredFiles", [])} != {
                "components/safe_browsing/core/common/safe_browsing_prefs.cc", "components/safe_browsing/core/common/safe_browsing_prefs.h"}):
        raise M15540EvidenceError("M155.40 pruning schedule mismatch")
    external = documents["pinned-build-inputs.json"]
    if (external.get("compilerMajor") != 24 or external.get("compilerStamp") != "llvmorg-24-init-7747-g62397f8b-27"
            or external.get("esbuildPackageVersion") != "0.28.2"
            or external.get("devtoolsTypeScriptVersion") != "7.0.2"
            or external.get("devtoolsTypeScriptDEPSPackage") != "chromium/third_party/typescript/mac-arm64"
            or external.get("devtoolsTypeScriptDEPSVersion") != "version:2@7.0.2"
            or external.get("dsymutilObjectSHA1") != "d72733d9365a8c75966b524a739bccb23151a021"
            or external.get("gnProof", {}).get("enable_cpp_api_from_rust") is not True
            or external["gnProof"].get("rust_sysroot_absolute") != "" or external["gnProof"].get("rustc_version") != ""):
        raise M15540EvidenceError("M155.40 pinned build toolchain mismatch")
    required_inputs = {
        "third_party/llvm-build/Release+Asserts/bin/clang", "third_party/llvm-build/Release+Asserts/cr_build_revision",
        "third_party/rust-toolchain/bin/rustc", "third_party/rust-toolchain/bin/bindgen", "third_party/rust-toolchain/bin/cc_bindings_from_rs",
        "third_party/rust-toolchain/VERSION", "buildtools/mac/gn", "third_party/ninja/ninja",
        "third_party/devtools-frontend/src/third_party/esbuild/esbuild", "third_party/devtools-frontend/src/node_modules/esbuild/package.json",
        "tools/clang/dsymutil/bin/dsymutil", "tools/clang/dsymutil/bin/dsymutil.arm64.sha1",
        "third_party/typescript/mac-arm64/src/lib/tsc",
    }
    if len(external.get("inputs", [])) != len(required_inputs) or {i.get("path") for i in external["inputs"]} != required_inputs:
        raise M15540EvidenceError("M155.40 pinned build input set is incomplete")
    for item in external["inputs"]:
        require_hash(item.get("sha256"), "pinned build input")
    verify_restored_build_types(external.get("restoredBuildTypes"))
    return contract, snapshot


def verify_restored_build_types(report: object, source: Path | None = None) -> None:
    if not isinstance(report, dict) or (
        report.get("version") != "7.18.2"
        or report.get("targetVersion") != VERSION or report.get("releaseReady") is not False
        or report.get("status") != "restored-exact-package-lock-build-types"
        or report.get("reference") != "https://registry.npmjs.org/undici-types/-/undici-types-7.18.2.tgz"
        or report.get("archiveSHA256") != "4d92799b0e619468a30f70eff033c1a27e713134a4ff353e1a6794f67e425497"
        or report.get("packageLockSHA256") != "9f2164bb3613fced8baa366624c40e0ed27a1bc1198892834c3f53bf07130e2e"
        or report.get("integrity") != "sha512-AsuCzffGHJybSaRrmr5eHr81mwJU3kjw6M+uprWvCXiNeN9SOGwQ3Jn8jb8m3Z6izVgknn1R0FTCEAP2QrLY/w=="
    ):
        raise M15540EvidenceError("M155.40 restored build types are not the pinned package")
    files = report.get("files", [])
    names = [item.get("path", "") for item in files]
    prefix = "third_party/node/node_modules/undici-types/"
    if len(files) != 43 or len(set(names)) != 43 or any(
        not name.startswith(prefix) or "/" in name[len(prefix):] or not name.endswith(".d.ts")
        for name in names
    ):
        raise M15540EvidenceError("M155.40 restored type input set is incomplete or unsafe")
    for item in files:
        require_hash(item.get("sha256"), "restored build type")
        if source is not None and sha256_file(safe_relative_regular(source, item["path"])) != item["sha256"]:
            raise M15540EvidenceError("M155.40 restored build type changed")
    if source is not None and sha256_file(safe_relative_regular(source, "third_party/node/package-lock.json")) != report["packageLockSHA256"]:
        raise M15540EvidenceError("M155.40 Node package lock changed")

def verify_candidate_document(
    document: dict[str, Any], *, project_root: Path, source_root: Path | None = None
) -> None:
    runtime = project_root.resolve() / "runtime"
    canonical = read_object(runtime / f"{PREFIX}-port-candidate.json", "M155.40 candidate")
    if document != canonical:
        raise M15540EvidenceError("M155.40 candidate differs from canonical evidence")
    contract, snapshot = verify_contract(project_root)
    if (document.get("schemaVersion") != 1
            or document.get("status") != "candidate-bound"
            or document.get("releaseReady") is not False
            or document.get("targetChromiumVersion") != VERSION
            or document.get("targetArchitecture") != "arm64"
            or document.get("sourceContractSHA256") != sha256_file(runtime / f"{PREFIX}-source-contract.json")
            or document.get("sourceInputManifestSHA256") != contract["sourceInputManifestSHA256"]
            or document.get("sourceSnapshotSHA256") != contract["sourceSnapshotSHA256"]):
        raise M15540EvidenceError("M155.40 candidate source binding mismatch")
    binding = document.get("binaryBinding", {})
    if not isinstance(binding, dict) or (binding.get("status"), binding.get("sourceVersion"), binding.get("architecture")) != ("bound-to-built-candidate", VERSION, "arm64"):
        raise M15540EvidenceError("M155.40 candidate binary binding is absent")
    for key in ("argsGNSHA256", "candidateExecutableSHA256", "candidateFrameworkSHA256"):
        require_hash(binding.get(key), key)
    if binding["argsGNSHA256"] != contract["buildArgsSHA256"]:
        raise M15540EvidenceError("M155.40 binary was built with different args")
    reject_local_paths(document, "M155.40 candidate")
    if source_root is not None:
        relative = snapshot["argsGN"]["relativePath"]
        current = compact_snapshot(build_snapshot(source_root, source_root / relative))
        if current != snapshot:
            raise M15540EvidenceError("M155.40 live source differs from frozen snapshot")
        external = read_object(runtime / f"{PREFIX}-source-evidence/pinned-build-inputs.json", "M155.40 pinned build inputs")
        verify_restored_build_types(external.get("restoredBuildTypes"), source_root)
        for item in external["inputs"]:
            path = safe_relative_regular(source_root, item["path"])
            if sha256_file(path) != item["sha256"]:
                raise M15540EvidenceError("M155.40 pinned build input changed")

        for name, expected in final_overlay_postimages(runtime).items():
            if sha256_file(safe_relative_regular(source_root, name)) != expected:
                raise M15540EvidenceError("M155.40 final source postimage mismatch")


def verify_unsigned_binary_binding(app: Path, args_gn: Path, document: dict[str, Any]) -> None:
    if app.is_symlink() or not app.is_dir():
        raise M15540EvidenceError("M155.40 unsigned app is missing or symlinked")
    app = app.resolve()
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    name = info.get("CFBundleExecutable")
    if (not isinstance(name, str) or not name or "/" in name
            or info.get("CFBundleShortVersionString") != VERSION):
        raise M15540EvidenceError("M155.40 unsigned app identity mismatch")
    binding = document.get("binaryBinding", {})
    paths = (
        (app / "Contents/MacOS" / name, "candidateExecutableSHA256"),
        (app / "Contents/Frameworks/NeAntik Browser Framework.framework/Versions" / VERSION
         / "NeAntik Browser Framework", "candidateFrameworkSHA256"),
        (args_gn, "argsGNSHA256"),
    )
    for path, key in paths:
        if path.is_symlink() or not path.is_file() or sha256_file(path) != require_hash(binding.get(key), key):
            raise M15540EvidenceError(f"M155.40 unsigned {key} mismatch")
        if key != "argsGNSHA256" and not path.resolve().is_relative_to(app):
            raise M15540EvidenceError("M155.40 unsigned binary escapes its app")


def verify_candidate_lock(
    lock: dict[str, Any], *, provenance: dict[str, Any], project_root: Path
) -> None:
    runtime = project_root.resolve() / "runtime"
    canonical = read_object(runtime / "fingerprint-chromium-15540.lock.json", "M155.40 candidate lock")
    if lock != canonical:
        raise M15540EvidenceError("M155.40 lock differs from canonical candidate")
    verify_candidate_document(provenance, project_root=project_root)
    if (lock.get("schemaVersion") != 4 or lock.get("status") != "source-qualified"
            or lock.get("releaseReady") is not False
            or lock.get("targetArchitecture") != "arm64"
            or lock.get("fingerprintChromium", {}).get("chromiumVersion") != VERSION
            or lock.get("fingerprintChromium", {}).get("commit") != COMMIT
            or lock.get("fingerprintChromium", {}).get("tree") != TREE
            or lock.get("sourceContractSHA256") != sha256_file(runtime / f"{PREFIX}-source-contract.json")
            or lock.get("sourceProvenanceSHA256") != sha256_file(runtime / f"{PREFIX}-port-candidate.json")):
        raise M15540EvidenceError("M155.40 candidate lock binding mismatch")
    plan = read_object(runtime / f"{PREFIX}-rebase-plan.json", "M155.40 plan")
    for lock_key, plan_key in (("commonChromium", "upstreamCommonOverlay"), ("macPackaging", "upstreamMacPackaging")):
        actual, expected = lock.get(lock_key, {}), plan[plan_key]
        if any(actual.get(key) != expected.get(key) for key in ("repository", "commit", "tree")):
            raise M15540EvidenceError("M155.40 upstream lock identity mismatch")
    if (lock.get("sourceContract") != f"runtime/{PREFIX}-source-contract.json"
            or lock.get("sourceProvenance") != f"runtime/{PREFIX}-port-candidate.json"
            or lock.get("macPackaging", {}).get("packagedChromiumVersion") != VERSION
            or lock.get("binaryBinding", {}).get("requiredEvidence") != f"runtime/{PREFIX}-port-candidate.json"
            or lock.get("ownedManifests", {}).get("securityBaselineSHA256") != sha256_file(bound_baseline_path(runtime, lock.get("ownedManifests", {}).get("securityBaselineSHA256")))):
        raise M15540EvidenceError("M155.40 lock paths or manifest binding mismatch")
    verify_tuple_runtime_qualification(lock, provenance, runtime)
    reject_local_paths(lock, "M155.40 candidate lock")


def verify_packaged_tuple_qualification(project_root: Path, packaged_evidence: Path,
                                        lock: dict[str, Any]) -> None:
    verification = lock.get("verification", {})
    if verification.get("coherentAppleDeviceTuples") != "verified":
        return
    name = "coherent-apple-device-tuples-runtime-qualification.json"
    relative = f"{PREFIX}-source-evidence/{name}"
    packaged = safe_relative_regular(packaged_evidence, relative)
    reviewed = safe_relative_regular(project_root / "runtime", relative)
    if (sha256_file(packaged) != require_hash(verification.get("coherentAppleDeviceTuplesEvidenceSHA256"), "packaged tuple evidence")
            or packaged.read_bytes() != reviewed.read_bytes()):
        raise M15540EvidenceError("Packaged M155.40 tuple qualification differs from reviewed evidence")


def verify_tuple_runtime_qualification(
    lock: dict[str, Any], candidate: dict[str, Any], runtime: Path
) -> None:
    verification = lock.get("verification")
    if not isinstance(verification, dict) or verification.get("coherentAppleDeviceTuples") != "verified":
        return
    relative = f"runtime/{PREFIX}-source-evidence/coherent-apple-device-tuples-runtime-qualification.json"
    if verification.get("coherentAppleDeviceTuplesEvidence") != relative:
        raise M15540EvidenceError("M155.40 verified tuple evidence path is not pinned")
    path = runtime.parent / relative
    evidence = read_object(path, "M155.40 verified tuple evidence")
    if verification.get("coherentAppleDeviceTuplesEvidenceSHA256") != sha256_file(path):
        raise M15540EvidenceError("M155.40 verified tuple evidence digest mismatch")
    reject_local_paths(evidence, "M155.40 verified tuple evidence")
    memory = evidence.get("deviceMemory")
    if (evidence.get("schemaVersion") != 1 or evidence.get("status") != "verified"
            or evidence.get("chromiumVersion") != VERSION
            or evidence.get("guiProductionQualified") is not True
            or evidence.get("releaseReady") is not False
            or not isinstance(memory, dict) or memory.get("coherent") is not True):
        raise M15540EvidenceError("M155.40 tuple runtime qualification is incomplete")
    if evidence.get("sourceCandidateSHA256") != sha256_file(runtime / f"{PREFIX}-port-candidate.json"):
        raise M15540EvidenceError("M155.40 tuple evidence is bound to another source candidate")
    if evidence.get("tupleCatalogSHA256") != sha256_file(runtime / "apple-device-tuples.json"):
        raise M15540EvidenceError("M155.40 tuple evidence uses another device catalog")
    binding = candidate.get("binaryBinding", {})
    if evidence.get("unsignedFrameworkSHA256") != binding.get("candidateFrameworkSHA256"):
        raise M15540EvidenceError("M155.40 tuple evidence uses another unsigned framework")
    js = memory.get("js")
    if not isinstance(js, (int, float)) or isinstance(js, bool) or js <= 0:
        raise M15540EvidenceError("M155.40 Device Memory JS evidence is invalid")
    for kind in ("navigation", "subresource"):
        headers = memory.get(kind)
        if not isinstance(headers, dict) or any(headers.get(name) != str(js) for name in ("modern", "legacy")):
            raise M15540EvidenceError(f"M155.40 {kind} Device Memory evidence is incoherent")
    for key in (
        "signedRuntimeExecutableSHA256", "signedRuntimeFrameworkSHA256",
        "candidateManifestSHA256", "authenticatedGUIEnvelopeSHA256",
        "publicSafeGUISummarySHA256",
    ):
        require_hash(evidence.get(key), key)
