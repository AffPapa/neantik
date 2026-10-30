#!/usr/bin/env python3
"""Bind evidence for the one already-running Chromium 156.80 Ninja build.

This helper never launches Ninja. It requires the operator to pass the actual
exit code returned by that running invocation, then checks the exact source,
configuration, terminal Ninja action count, executable version and output hashes.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import plistlib
import re
import subprocess
import sys
from pathlib import Path

import chromium_15680_release_evidence as evidence


def sha(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def write_json(path: Path, value: dict) -> None:
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    temporary.replace(path)


def select_chromium_browser(candidates: list[Path]) -> tuple[Path, str]:
    matching: list[tuple[Path, str]] = []
    for candidate in candidates:
        if not candidate.is_file() or candidate.is_symlink():
            continue
        result = subprocess.run([str(candidate), "--version"], text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                check=False, timeout=30)
        version_text = result.stdout.strip()
        if result.returncode == 0 and evidence.VERSION in version_text:
            matching.append((candidate, version_text))
    if len(matching) != 1:
        raise evidence.M15680EvidenceError(
            "expected exactly one executable reporting Chromium 156.0.8078.80"
        )
    return matching[0]


def select_chromium_framework(output_dir: Path) -> Path:
    # GN emits the versioned framework at the output root. Do not recursively
    # scan the bundle: interrupted/previous builds can leave stale app bundles
    # and dSYMs beside the current output.
    framework = (output_dir / "NeAntik Browser Framework.framework" / "Versions" /
                 evidence.VERSION / "NeAntik Browser Framework")
    if framework.is_symlink() or not framework.is_file():
        raise evidence.M15680EvidenceError(
            "pinned Chromium 156.0.8078.80 Framework binary is missing or unsafe"
        )
    return framework


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source_root", type=Path)
    parser.add_argument("--project-root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--ninja-log", type=Path, required=True)
    parser.add_argument("--ninja-exit-code", type=int, required=True,
                        help="actual exit code returned by the already-running Ninja command")
    args = parser.parse_args()
    try:
        project = args.project_root.resolve()
        source = args.source_root.resolve(strict=True)
        if args.source_root.is_symlink() or not args.source_root.is_absolute():
            raise evidence.M15680EvidenceError("source root must be an absolute, non-symlink path")
        if args.ninja_exit_code != 0:
            raise evidence.M15680EvidenceError("Ninja did not exit successfully; build evidence was not written")
        log = args.ninja_log.resolve(strict=True)
        if args.ninja_log.is_symlink() or not log.is_file():
            raise evidence.M15680EvidenceError("Ninja log must be a regular non-symlink file")

        verified = evidence.verify_source_root(source, project)
        adoption = verified["adoption"]
        output_dir = source / adoption["buildOutputDirectory"]
        if not output_dir.is_dir() or output_dir.is_symlink():
            raise evidence.M15680EvidenceError("pinned Chromium output directory is missing or unsafe")
        actions = re.findall(rb"\[(\d+)/(\d+)\]", log.read_bytes())
        if not actions:
            raise evidence.M15680EvidenceError("Ninja log contains no completed action counters")
        completed, total = map(int, actions[-1])
        if completed != total:
            raise evidence.M15680EvidenceError("Ninja log does not show all target actions completed")

        browser_candidates = [output_dir / "chrome"]
        for app_name in ("NeAntik Browser.app", "Chromium.app"):
            app = output_dir / app_name
            info = app / "Contents/Info.plist"
            if info.is_file() and not info.is_symlink():
                with info.open("rb") as stream:
                    bundle = plistlib.load(stream)
                executable = bundle.get("CFBundleExecutable")
                if isinstance(executable, str) and executable and "/" not in executable:
                    browser_candidates.append(app / "Contents/MacOS" / executable)
        browser, version_text = select_chromium_browser(browser_candidates)
        architecture = subprocess.run(["/usr/bin/lipo", "-archs", str(browser)], text=True,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
        if architecture.returncode != 0 or architecture.stdout.strip() != "arm64":
            raise evidence.M15680EvidenceError("built Chromium executable is not arm64-only")
        framework = select_chromium_framework(output_dir)
        framework_architecture = subprocess.run(
            ["/usr/bin/lipo", "-archs", str(framework)], text=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
        )
        if framework_architecture.returncode != 0 or framework_architecture.stdout.strip() != "arm64":
            raise evidence.M15680EvidenceError("built Chromium Framework is not arm64-only")
        contract = evidence.verify_contract(project)
        if (sha(source / "chrome/VERSION") != adoption["chromeVersionFileSHA256"] or
                sha(source / adoption["buildOutputDirectory"] / "args.gn") != contract["buildArgsSHA256"]):
            raise evidence.M15680EvidenceError("source version or accepted GN args changed during build")

        report = {
            "schemaVersion": 1, "status": "chromium-source-build-succeeded-unqualified",
            "chromiumVersion": evidence.VERSION, "targetArchitecture": "arm64",
            "officialCommit": evidence.COMMIT, "officialTree": evidence.TREE,
            "buildConfigurationSHA256": contract["buildArgsSHA256"],
            "sourcePatchSHA256": contract["sourcePatchSHA256"],
            "dependencyLockSHA256": contract["dependencyLockSHA256"],
            "gclientConfigSHA256": contract["gclientConfigSHA256"],
            "gclientEntriesSHA256": contract["gclientEntriesSHA256"],
            "gcsEntriesSHA256": contract["gcsEntriesSHA256"],
            "ninjaTarget": "chrome", "ninjaActionsCompleted": completed,
            "ninjaActionsExpected": total, "ninjaExitCode": 0,
            "buildLogSHA256": sha(log), "browserExecutableSHA256": sha(browser),
            "browserExecutableRelativePath": str(browser.relative_to(source)),
            "frameworkSHA256": sha(framework), "versionCommand": version_text + "; exit 0",
            "frameworkRelativePath": str(framework.relative_to(source)),
            "signature": "not evaluated by source-build evidence; Developer ID signing remains open",
            "buildOutputDirectory": adoption["buildOutputDirectory"], "releaseReady": False,
        }
        runtime = project / "runtime"
        write_json(runtime / "chromium-15680-build-evidence.json", report)
        adoption["status"] = "source-port-patch-frozen-build-complete"
        adoption["buildEvidenceSHA256"] = sha(runtime / "chromium-15680-build-evidence.json")
        adoption["validation"]["arm64ChromeBuild"] = "PASS; this exact Ninja invocation; unqualified"
        write_json(runtime / evidence.ADOPTION, adoption)
        contract["sourceAdoptionManifestSHA256"] = sha(runtime / evidence.ADOPTION)
        contract["buildEvidenceSHA256"] = adoption["buildEvidenceSHA256"]
        contract["buildEvidenceStatus"] = "completed-build-verified-runtime-report-pending"
        contract["binaryBindingStatus"] = "pending-runtime-report"
        contract["status"] = "build-complete-runtime-report-pending"
        write_json(runtime / evidence.CONTRACT, contract)
        print(json.dumps(report, sort_keys=True))
        return 0
    except (OSError, ValueError, subprocess.TimeoutExpired, KeyError) as error:
        print(f"Chromium 156.80 build evidence was not written: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
