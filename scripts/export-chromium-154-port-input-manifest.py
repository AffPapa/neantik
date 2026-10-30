#!/usr/bin/env python3
"""Export diagnostic source-input provenance for the locked M154 port.

The output binds a disposable source tree, the reviewed M154 port experiment,
canonical Apple tuple inputs, Safe Browsing mode, and GN args. It does not
qualify the runtime, signing, notarization, Gatekeeper, publication, or release.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import sys
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
COMMON_EXPORTER_PATH = (
    PROJECT_ROOT / "scripts" / "export-chromium-153-port-input-manifest.py"
)
PORT_EXPERIMENT_PATH = (
    PROJECT_ROOT
    / "runtime"
    / "nevision-patches"
    / "ports"
    / "chromium-154.0.8037.93"
    / "port-experiment.json"
)
DIAGNOSTIC_STATUS_PATH = (
    PROJECT_ROOT / "runtime" / "chromium-154-diagnostic-status.json"
)
TUPLE_GENERATOR_PATH = (
    PROJECT_ROOT / "scripts" / "apply-owned-runtime-device-tuples-154.py"
)
TUPLE_CATALOG_PATH = PROJECT_ROOT / "runtime" / "apple-device-tuples.json"
SECURITY_BASELINE_PATH = PROJECT_ROOT / "runtime" / "security-baseline.json"
UPSTREAM_MACOS_PATCH_ROOT = (
    PROJECT_ROOT
    / "runtime"
    / "nevision-patches"
    / "upstream"
    / "ungoogled-chromium-macos"
    / "154.0.8037.57-1.1"
    / "patches"
)
EXPECTED_VERSION = "154.0.8037.93"
EXPECTED_COMMIT = "f89f3a4363808e117c592adedcf9947882ac3b79"
EXPECTED_TREE = "658e81c77627fcf91e6784bd353e0d31a4ca70b5"
EXPECTED_SAFE_BROWSING_MODE = 0


class ManifestError(ValueError):
    pass


def load_common_exporter():
    spec = importlib.util.spec_from_file_location(
        "chromium153_port_input_manifest", COMMON_EXPORTER_PATH
    )
    if spec is None or spec.loader is None:
        raise ManifestError("could not load the shared source-input exporter")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def require_gn_value(args_text: str, name: str, expected: str) -> None:
    match = re.search(
        rf'(?m)^\s*{re.escape(name)}\s*=\s*([^\s#]+)\s*(?:#.*)?$',
        args_text,
    )
    if match is None or match.group(1).strip('"') != expected:
        raise ManifestError(f"args.gn must pin {name}={expected}")


def upstream_macos_patch_inputs(common, experiment: dict[str, object]) -> dict[str, object]:
    record = experiment.get("upstreamMacPackagingCurrent", {})
    replay = experiment.get("m154MacPackagingSeriesReplay", {})
    if (
        record.get("releaseTag") != "154.0.8037.57-1.1"
        or record.get("releaseCommit") != "3241dc9cacee393621d277ec936376072f0cb3c5"
        or record.get("releaseTree") != "ef5ef849ed78edb7d8c07773df6bbb6753efe9ea"
        or record.get("seriesSHA256") != replay.get("seriesSHA256")
        or record.get("seriesPatchCount") != replay.get("patchCount")
    ):
        raise ManifestError("pinned M154 macOS packaging source record is missing or inconsistent")
    series_path = UPSTREAM_MACOS_PATCH_ROOT / "series"
    if series_path.is_symlink() or not series_path.is_file():
        raise ManifestError("pinned M154 macOS packaging series is missing or unsafe")
    series_digest = common.sha256_file(series_path)
    if series_digest != record.get("seriesSHA256"):
        raise ManifestError("pinned M154 macOS packaging series digest mismatch")
    patch_entries = []
    lines = series_path.read_text(encoding="utf-8").splitlines()
    if len(lines) != record.get("seriesPatchCount"):
        raise ManifestError("pinned M154 macOS packaging series count mismatch")
    expected_digests = replay.get("patchSHA256", {})
    if set(expected_digests) != set(lines):
        raise ManifestError("pinned M154 macOS packaging patch digest index mismatch")
    for relative in lines:
        safe_relative = common.safe_relative(relative)
        path = UPSTREAM_MACOS_PATCH_ROOT / safe_relative
        if path.is_symlink() or not path.is_file():
            raise ManifestError(f"pinned M154 macOS packaging patch is missing or unsafe: {relative}")
        observed = common.sha256_file(path)
        if observed != expected_digests[relative]:
            raise ManifestError(f"pinned M154 macOS packaging patch digest mismatch: {relative}")
        patch_entries.append(
            {
                "path": str(path.relative_to(PROJECT_ROOT)),
                "sha256": observed,
            }
        )
    return {
        "repository": record["repository"],
        "tag": record["releaseTag"],
        "commit": record["releaseCommit"],
        "tree": record["releaseTree"],
        "commonSubmoduleCommit": record["commonSubmoduleCommit"],
        "series": {
            "path": str(series_path.relative_to(PROJECT_ROOT)),
            "sha256": series_digest,
            "patchCount": len(lines),
        },
        "patches": patch_entries,
        "releaseReady": False,
    }


def version_from_file(path: Path) -> str:
    if not path.is_file():
        raise ManifestError(f"Chromium VERSION file is missing: {path}")
    pairs = dict(
        line.split("=", 1)
        for line in path.read_text(encoding="utf-8").splitlines()
        if "=" in line
    )
    try:
        return ".".join(pairs[key] for key in ("MAJOR", "MINOR", "BUILD", "PATCH"))
    except KeyError as error:
        raise ManifestError(f"Chromium VERSION lacks {error.args[0]}") from error


def find_patch_artifacts(common, source_root: Path) -> list[str]:
    raw = common.git(
        source_root,
        "ls-files",
        "--others",
        "--exclude-standard",
        "-z",
        binary=True,
    )
    assert isinstance(raw, bytes)
    return sorted(
        os.fsdecode(path)
        for path in raw.split(b"\0")
        if path and os.fsdecode(path).endswith((".rej", ".orig"))
    )


def require_output_path(
    path: Path, source_root: Path, label: str, suffix: str
) -> Path:
    if not path.is_absolute() or path.is_symlink():
        raise ManifestError(f"{label} must be an absolute non-symlink path")
    source_root = source_root.resolve()
    resolved = path.resolve()
    try:
        relative = resolved.relative_to(source_root)
    except ValueError as error:
        raise ManifestError(
            f"{label} must belong to the locked source checkout"
        ) from error
    if len(relative.parts) < 3 or relative.parts[0] != "out":
        raise ManifestError(f"{label} must be inside a Chromium out/<config> directory")
    if suffix == "args.gn" and (relative.name != suffix or not resolved.is_file()):
        raise ManifestError(
            "args.gn must be an output-directory args.gn file"
        )
    if suffix == ".app" and (
        not relative.name.endswith(suffix) or not resolved.is_dir()
    ):
        raise ManifestError("binary app must be an output-directory .app bundle")
    return resolved


def port_inputs(common) -> dict[str, object]:
    if not PORT_EXPERIMENT_PATH.is_file():
        raise ManifestError(f"M154 port experiment is missing: {PORT_EXPERIMENT_PATH}")
    experiment = json.loads(PORT_EXPERIMENT_PATH.read_text(encoding="utf-8"))
    base = experiment.get("officialChromiumBase", {})
    if (
        experiment.get("targetChromiumVersion") != EXPECTED_VERSION
        or base.get("commit") != EXPECTED_COMMIT
        or base.get("tree") != EXPECTED_TREE
    ):
        raise ManifestError("M154 port experiment does not match the locked source")

    apply_check = experiment.get("ownedPatchApplyCheck", {})
    groups = apply_check.get("groups", [])
    if not groups or [group.get("order") for group in groups] != list(
        range(1, len(groups) + 1)
    ):
        raise ManifestError("owned M154 patch groups must be a contiguous ordered sequence")
    common_overlay = experiment.get("upstreamCommonOverlay", {})
    group_checks_valid = True
    for group in groups:
        check = group.get("sequentialApplyCheck")
        if check == "passed":
            continue
        if check != "already-satisfied-by-common-overlay":
            group_checks_valid = False
            break
        postimage_path = group.get("commonPostimagePath")
        postimage_digest = group.get("commonPostimageSHA256")
        if (
            group.get("satisfiedByCommonSeriesSHA256") != common_overlay.get("seriesSHA256")
            or not isinstance(postimage_path, str)
            or not re.fullmatch(r"[0-9a-f]{64}", str(postimage_digest or ""))
        ):
            group_checks_valid = False
            break
    if (
        apply_check.get("applied", 0) + apply_check.get("preSatisfied", 0) != len(groups)
        or apply_check.get("failed") != 0
        or not group_checks_valid
    ):
        raise ManifestError(
            "M154 owned patch sequential apply checks are incomplete or failed"
        )
    ordered_attempt = apply_check.get("latestOrderedAttempt", {})
    postimage_manifest_digest = ordered_attempt.get(
        "wholeTreePostimageManifestSHA256", ""
    )
    postimage_manifest_path = ordered_attempt.get("wholeTreePostimageManifestPath", "")
    if (
        ordered_attempt.get("orderedGroupCount") != len(groups)
        or ordered_attempt.get("rejectedArtifactCount") != 0
        or not re.fullmatch(r"[0-9a-f]{64}", postimage_manifest_digest)
        or not isinstance(postimage_manifest_path, str)
        or not Path(postimage_manifest_path).is_absolute()
    ):
        raise ManifestError(
            "M154 full clean ordered replay and whole-tree postimage manifest are required"
        )
    manifest_path = Path(postimage_manifest_path)
    if manifest_path.is_symlink() or not manifest_path.is_file():
        raise ManifestError("M154 whole-tree postimage manifest file is missing or unsafe")
    if common.sha256_file(manifest_path) != postimage_manifest_digest:
        raise ManifestError("M154 whole-tree postimage manifest digest mismatch")
    if (
        not ordered_attempt.get("orderedReplayContinuationLogPath")
        or not ordered_attempt.get("orderedReplayContinuationLogSHA256")
    ):
        raise ManifestError("M154 ordered replay continuation evidence is missing")
    continuation_log = Path(ordered_attempt["orderedReplayContinuationLogPath"])
    if (
        not continuation_log.is_absolute()
        or continuation_log.is_symlink()
        or not continuation_log.is_file()
        or common.sha256_file(continuation_log)
        != ordered_attempt["orderedReplayContinuationLogSHA256"]
    ):
        raise ManifestError("M154 ordered replay continuation evidence digest mismatch")
    try:
        needed_postimages = {
            group["commonPostimagePath"]: (group["commonPostimageSHA256"], None)
            for group in groups
            if group.get("sequentialApplyCheck") == "already-satisfied-by-common-overlay"
        }
        header = None
        summary = None
        entry_count = 0
        with manifest_path.open(encoding="utf-8") as manifest_file:
            for line in manifest_file:
                record = json.loads(line)
                if header is None:
                    header = record
                elif record.get("record") == "summary":
                    summary = record
                else:
                    entry_count += 1
                    path = record.get("path")
                    if path in needed_postimages and record.get("record") == "file":
                        needed_postimages[path] = (
                            needed_postimages[path][0], record.get("sha256")
                        )
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ManifestError("M154 whole-tree postimage manifest is unreadable") from error
    if header is None or summary is None:
        raise ManifestError("M154 whole-tree postimage manifest is incomplete")
    expected_manifest_inputs = {
        "record": "header",
        "schema": "neantik-chromium-source-tree-v1",
        "chromiumCommit": EXPECTED_COMMIT,
        "chromiumTree": EXPECTED_TREE,
        "chromiumVersion": EXPECTED_VERSION,
        "ownedGroupCount": len(groups),
        "dependencyRevisionMapSHA256": ordered_attempt.get("dependencyRevisionMapSHA256"),
        "pruningListSHA256": ordered_attempt.get("pruningListSHA256"),
        "presentPruningListSHA256": ordered_attempt.get("presentPruningListSHA256"),
        "pruneMode": ordered_attempt.get("pruneMode"),
        "commonSeriesSHA256": common_overlay.get("seriesSHA256"),
        "commonApplyLogSHA256": ordered_attempt.get("commonApplyLogSHA256"),
    }
    if any(header.get(key) != value or value is None for key, value in expected_manifest_inputs.items()):
        raise ManifestError("M154 whole-tree postimage manifest source locks mismatch")
    if summary.get("record") != "summary" or summary.get("entries") != entry_count:
        raise ManifestError("M154 whole-tree postimage manifest record count mismatch")
    if any(
        expected != actual
        for expected, actual in needed_postimages.values()
    ):
        raise ManifestError("M154 common-overlay pre-satisfied postimage mismatch")
    patch_entries = []
    port_dir = PORT_EXPERIMENT_PATH.parent
    for group in groups:
        relative = common.safe_relative(group.get("patchFile", ""))
        patch_path = port_dir / relative
        if not patch_path.is_file():
            raise ManifestError(f"owned M154 patch is missing: {relative}")
        observed = common.sha256_file(patch_path)
        if observed != group.get("sha256"):
            raise ManifestError(f"owned M154 patch digest mismatch: {relative}")
        patch_entries.append(
            {
                "id": group.get("id"),
                "path": str(patch_path.relative_to(PROJECT_ROOT)),
                "sha256": observed,
            }
        )

    tuple_record = experiment.get("generatedAppleTupleOverlay", {})
    expected_tuple_inputs = {
        "generator": (TUPLE_GENERATOR_PATH, tuple_record.get("scriptSHA256")),
        "catalog": (TUPLE_CATALOG_PATH, tuple_record.get("catalogSHA256")),
    }
    tuple_inputs = {}
    for name, (path, expected_digest) in expected_tuple_inputs.items():
        if not path.is_file():
            raise ManifestError(f"canonical Apple tuple {name} is missing: {path}")
        observed = common.sha256_file(path)
        if observed != expected_digest:
            raise ManifestError(f"canonical Apple tuple {name} digest mismatch")
        tuple_inputs[name] = {
            "path": str(path.relative_to(PROJECT_ROOT)),
            "sha256": observed,
        }

    if not SECURITY_BASELINE_PATH.is_file():
        raise ManifestError(f"security baseline is missing: {SECURITY_BASELINE_PATH}")

    return {
        "portExperiment": {
            "path": str(PORT_EXPERIMENT_PATH.relative_to(PROJECT_ROOT)),
            "sha256": common.sha256_file(PORT_EXPERIMENT_PATH),
            "status": experiment.get("status"),
        },
        "ownedPatches": patch_entries,
        "upstreamMacPackagingPatches": upstream_macos_patch_inputs(common, experiment),
        "appleTupleInputs": tuple_inputs,
        "securityBaseline": {
            "path": str(SECURITY_BASELINE_PATH.relative_to(PROJECT_ROOT)),
            "sha256": common.sha256_file(SECURITY_BASELINE_PATH),
        },
    }


def source_toolchain_inputs(common, source_root: Path) -> dict[str, object]:
    if not DIAGNOSTIC_STATUS_PATH.is_file():
        raise ManifestError(
            f"M154 diagnostic status is missing: {DIAGNOSTIC_STATUS_PATH}"
        )
    status = json.loads(DIAGNOSTIC_STATUS_PATH.read_text(encoding="utf-8"))
    evidence = status.get("chromium154SourceToolchainEvidence", {})
    source = evidence.get("source", {})
    if (
        source.get("version") != EXPECTED_VERSION
        or source.get("commit") != EXPECTED_COMMIT
        or source.get("tree") != EXPECTED_TREE
        or evidence.get("releaseQualified") is not False
    ):
        raise ManifestError("M154 source toolchain evidence is missing or mismatched")

    verified_files: dict[str, dict[str, str]] = {}
    for section_name in ("rust", "dawnGo"):
        section = evidence.get(section_name, {})
        relative = section.get("sourceFile", "")
        if not relative or Path(relative).is_absolute() or ".." in Path(relative).parts:
            raise ManifestError(f"M154 {section_name} source path is unsafe")
        source_file = source_root / relative
        if source_file.is_symlink() or not source_file.is_file():
            raise ManifestError(
                f"M154 {section_name} source input is missing: {relative}"
            )
        observed = common.sha256_file(source_file)
        if observed != section.get("sourceFileSHA256"):
            raise ManifestError(
                f"M154 {section_name} source digest mismatch: {relative}"
            )
        verified_files[section_name] = {"path": relative, "sha256": observed}

    rust = evidence["rust"]
    rust_deps = (source_root / rust["sourceFile"]).read_text(encoding="utf-8")
    if (
        rust.get("objectName") not in rust_deps
        or rust.get("sha256") not in rust_deps
        or str(rust.get("sizeBytes")) not in rust_deps
    ):
        raise ManifestError("M154 Rust toolchain pin is not present in Chromium DEPS")
    dawn_go = evidence["dawnGo"]
    dawn_deps = (source_root / dawn_go["sourceFile"]).read_text(encoding="utf-8")
    if dawn_go.get("depsVersion") not in dawn_deps:
        raise ManifestError("M154 Dawn Go version is not present in Dawn DEPS")

    return {
        "statusPath": str(DIAGNOSTIC_STATUS_PATH.relative_to(PROJECT_ROOT)),
        "statusSHA256": common.sha256_file(DIAGNOSTIC_STATUS_PATH),
        "sourceFiles": verified_files,
        "rust": {
            "objectName": rust["objectName"],
            "sha256": rust["sha256"],
            "sizeBytes": rust["sizeBytes"],
            "rustcRevision": rust["rustcRevision"],
            "architecture": rust["architecture"],
        },
        "dawnGo": {
            "package": dawn_go["package"],
            "depsVersion": dawn_go["depsVersion"],
            "instanceId": dawn_go["instanceId"],
            "architecture": dawn_go["architecture"],
        },
        "releaseQualified": False,
    }


def build_manifest(
    source_root: Path,
    args_gn_path: Path,
    binary_app: Path | None = None,
) -> dict[str, object]:
    if (
        not source_root.is_absolute()
        or source_root.is_symlink()
        or not source_root.is_dir()
    ):
        raise ManifestError("source root must be an absolute non-symlink directory")
    common = load_common_exporter()
    source_root = source_root.resolve()
    args_gn_path = require_output_path(args_gn_path, source_root, "args.gn", "args.gn")
    if binary_app is not None:
        binary_app = require_output_path(
            binary_app, source_root, "binary app", ".app"
        )

    commit = str(common.git(source_root, "rev-parse", "HEAD"))
    tree = str(common.git(source_root, "rev-parse", "HEAD^{tree}"))
    observed_version = version_from_file(source_root / "chrome" / "VERSION")
    if (commit, tree, observed_version) != (
        EXPECTED_COMMIT,
        EXPECTED_TREE,
        EXPECTED_VERSION,
    ):
        raise ManifestError(
            "source lock mismatch: expected Chromium "
            f"{EXPECTED_VERSION} {EXPECTED_COMMIT}/{EXPECTED_TREE}, observed "
            f"{observed_version} {commit}/{tree}"
        )

    args_text = args_gn_path.read_text(encoding="utf-8")
    require_gn_value(args_text, "target_cpu", "arm64")
    require_gn_value(args_text, "angle_enable_metal", "true")
    require_gn_value(args_text, "dawn_enable_metal", "true")
    require_gn_value(args_text, "safe_browsing_mode", "0")
    require_gn_value(args_text, "enterprise_cloud_content_analysis", "true")

    patch_artifacts = find_patch_artifacts(common, source_root)
    if patch_artifacts:
        preview = ", ".join(patch_artifacts[:12])
        remainder = len(patch_artifacts) - min(12, len(patch_artifacts))
        suffix = f", and {remainder} more" if remainder else ""
        raise ManifestError(
            f"source contains {len(patch_artifacts)} untracked .rej/.orig "
            f"patch artifacts: {preview}{suffix}"
        )

    source_manifest = common.build_manifest(
        source_root,
        prefixes=("out",),
        binary_app=binary_app,
        args_gn=args_gn_path if binary_app is not None else None,
    )
    inputs = port_inputs(common)
    inputs["sourceToolchainInputs"] = source_toolchain_inputs(common, source_root)
    inputs["manifestExporters"] = {
        "chromium154": {
            "path": str(Path(__file__).resolve().relative_to(PROJECT_ROOT)),
            "sha256": common.sha256_file(Path(__file__).resolve()),
        },
        "shared": {
            "path": str(COMMON_EXPORTER_PATH.relative_to(PROJECT_ROOT)),
            "sha256": common.sha256_file(COMMON_EXPORTER_PATH),
        },
    }
    return {
        "schemaVersion": 1,
        "status": "diagnostic-source-only",
        "releaseReady": False,
        "targetChromiumVersion": EXPECTED_VERSION,
        "officialChromiumBase": {
            "commit": EXPECTED_COMMIT,
            "tree": EXPECTED_TREE,
        },
        "safeBrowsingMode": EXPECTED_SAFE_BROWSING_MODE,
        "enterpriseCloudContentAnalysis": True,
        "sourceEvidence": source_manifest,
        "argsGN": {
            "path": str(args_gn_path),
            "sha256": common.sha256_file(args_gn_path),
        },
        **inputs,
        "policy": (
            "This is diagnostic source-input provenance only. It does not "
            "qualify a complete build, runtime behavior, profile isolation, "
            "network privacy, signing, notarization, Gatekeeper, publication, "
            "or release readiness."
        ),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("source_root", type=Path)
    parser.add_argument("--args-gn", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--binary-app", type=Path)
    args = parser.parse_args()
    try:
        if not args.output.is_absolute():
            raise ManifestError("output must be absolute")
        output = args.output.resolve()
        manifest = build_manifest(args.source_root, args.args_gn, args.binary_app)
        output.parent.mkdir(parents=True, exist_ok=True)
        temporary = output.with_name(output.name + ".tmp")
        temporary.write_text(
            json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        temporary.replace(output)
    except (ManifestError, OSError, json.JSONDecodeError) as error:
        print(
            f"Chromium 154 diagnostic manifest export failed: {error}",
            file=sys.stderr,
        )
        return 1

    print(f"Chromium 154 diagnostic source manifest: {output}")
    print(
        "Tracked diff SHA-256: "
        f"{manifest['sourceEvidence']['git']['trackedDiffSHA256']}"
    )
    print(f"Untracked input count: {manifest['sourceEvidence']['untrackedFileCount']}")
    print("Safe Browsing mode: 0")
    print("Release ready: false")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
