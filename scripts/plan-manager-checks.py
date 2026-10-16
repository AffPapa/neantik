#!/usr/bin/env python3
"""Read-only check selection. Recommendations never execute or certify checks."""
import argparse
import importlib.util
import json
from pathlib import Path, PurePosixPath
import re
import subprocess

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("manager_fast_plan", ROOT / "scripts/test-manager-fast.py")
fast = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fast)

# Conservative reviewed boundaries. Shared models and unknown sources need full
# regression; a matching name alone is not evidence that a test covers behavior.
FEATURES = [
    (r"Sources/NeAntik/WebKit[^/]*\.swift$", "webkit",
     r"^(WebKit|BrowserLaunch|BrowserProcessManager|ProfileCommands|MCPProfileManagement)",
     "headed WebKit lifecycle/isolation and changed capabilities"),
    (r"Sources/NeAntik/(Proxy[^/]*|BrowserRoute[^/]*|BrowserRelay[^/]*)\.swift$", "network",
     r"^(Proxy|BrowserRoute|BrowserRelay|BrowserLaunch|BrowserProcessManager|MCPProfileManagement)",
     "controlled browser route/failure checks, synthetic credentials only"),
    (r"Sources/NeAntik/(ProfileBrowserDataBackup[^/]*|EncryptedBackup[^/]*)\.swift$", "backup",
     r"^(ProfileBrowserDataBackup|BrowserDataBackup|EncryptedBackup|ProfileCommands|ProfileStore)",
     "real isolated backup restore/interruption; original Mac/Keychain limits"),
    (r"Sources/NeAntik/(CRX[^/]*|BrowserExtension[^/]*)\.swift$", "extensions",
     r"^(CRX|BrowserExtension|ProfileCommands|ProfileStore)",
     "actual own native extension lifecycle if install behavior changes"),
    (r"Sources/NeAntik/MCP[^/]*\.swift$", "mcp",
     r"^(MCP|ProfileStore|WebKitProfile)",
     "exact isolated stdio capability/revision/refusal integration"),
]

# Reviewed stdlib-only harness boundaries. These do not link Swift or share
# production code. Changes outside this explicit map remain conservative.
STANDALONE_HARNESSES = {
    'scripts/runtime-network/manager-route-fixture.py': ('scripts.tests.test_shipping_manager_route_fixture', 'scripts.tests.test_controlled_dns_fixture', 'scripts.tests.test_manager_dns_fixture'),
    'scripts/runtime-network/controlled-dns-fixture.py': ('scripts.tests.test_controlled_dns_fixture', 'scripts.tests.test_manager_dns_fixture'),
    'scripts/runtime-network/manager-dns-fixture.py': 'scripts.tests.test_manager_dns_fixture',
    'scripts/runtime-network/collect-manager-dns.py': ('scripts.tests.test_manager_dns_custody', 'scripts.tests.test_manager_dns_analysis'),
    'scripts/runtime-network/analyze-manager-dns.py': 'scripts.tests.test_manager_dns_analysis',
    'scripts/runtime-network/manager-dns-transition.py': 'scripts.tests.test_manager_dns_analysis',
    'scripts/runtime-network/analyze-controlled-dns.py': 'scripts.tests.test_controlled_dns_analysis',
    'scripts/runtime-network/run-controlled-dns.mjs': 'scripts.tests.test_controlled_dns_analysis',
    'scripts/runtime-network/analyze-manager-route.py': 'scripts.tests.test_shipping_manager_route_analysis',
    'scripts/controlled-browser-route-observer.py': ('scripts.tests.test_controlled_browser_route_observer', 'scripts.tests.test_background_netlog_observer'),
}


def safe_path(value):
    path = PurePosixPath(value)
    if not value or path.is_absolute() or ".." in path.parts or path.parts[:1] == (".secrets",):
        raise ValueError("Provide a repository-relative source path")
    return path.as_posix()


def changed_paths(base, root=ROOT):
    sha = subprocess.check_output(["git", "rev-parse", "--verify", "--end-of-options", base + "^{commit}"], cwd=root, text=True).strip()
    diff = subprocess.check_output(["git", "diff", "--no-renames", "--name-only", "-z", sha, "--"], cwd=root)
    new = subprocess.check_output(["git", "ls-files", "--others", "--exclude-standard", "-z"], cwd=root)
    return sha, sorted({safe_path(p.decode()) for p in (diff + new).split(b"\0") if p})


def plan(paths, catalog):
    paths = sorted({safe_path(p) for p in paths})
    selected = set(); python = set(); reasons = []; gates = set(); full = False; python_full = False; delivery = False
    for path in paths:
        if PurePosixPath(path).suffix.lower() in (".zip", ".dmg", ".sha256", ".sig", ".provisionprofile") or ".app/" in path or PurePosixPath(path).name.startswith("direct-candidate"):
            delivery = True
            gates.add("exact source/candidate binding, signing, notarization, stapling, Gatekeeper and archive integrity")
            gates.add("published-byte identity and isolated headed launch for changed delivery; preserve immutable old assets")
            reasons.append({"path": path, "surface": "release-delivery"}); continue
        if path.startswith("releases/") and path.endswith(".json"):
            delivery = True
            gates.add("reconcile release metadata with actual candidate/source/runtime hashes, registered artifacts and live state")
            reasons.append({"path": path, "surface": "release-metadata"}); continue
        if path.startswith("runtime/"):
            full = True; python_full = True; gates.add("runtime patch/apply/build/provenance and exact headed vector controls")
            reasons.append({"path": path, "surface": "runtime"}); continue
        if path.startswith("Tests/NeAntikTests/") and path.endswith("Tests.swift"):
            suite = PurePosixPath(path).stem
            if suite in catalog: selected.add(suite)
            else: full = True
            reasons.append({"path": path, "surface": "swift-test"}); continue
        match = next((f for f in FEATURES if re.fullmatch(f[0], path)), None)
        if match:
            found = {s for s in catalog if re.search(match[2], s)}
            if found: selected |= found
            else: full = True
            gates.add(match[3]); reasons.append({"path": path, "surface": match[1]}); continue
        if path.startswith("scripts/tests/") and re.fullmatch(r"test_[A-Za-z0-9_]+\.py", PurePosixPath(path).name):
            python.add(path[:-3].replace("/", ".")); reasons.append({"path": path, "surface": "python-test"}); continue
        if path in STANDALONE_HARNESSES:
            modules = STANDALONE_HARNESSES[path]
            python.update((modules,) if isinstance(modules, str) else modules)
            gates.add('owned network fixture controls; offline analysis is distinct from fresh headed execution')
            reasons.append({'path': path, 'surface': 'standalone-network-harness'}); continue
        if path == 'scripts/native-qa-readiness.py':
            python.add('scripts.tests.test_native_qa_readiness')
            gates.add('real read-only macOS resource observation; readiness is not native qualification')
            reasons.append({'path': path, 'surface': 'native-qa-readiness'}); continue
        if path == 'scripts/compare-release-reports.py':
            python.add('scripts.tests.test_compare_release_reports')
            gates.add('actual public before/after records; matching measurement conditions and native behavior remain separate acceptance')
            reasons.append({'path': path, 'surface': 'release-report-comparison'}); continue
        if path == 'scripts/prepare_runtime_common_evidence.py':
            python.add('scripts.tests.test_prepare_runtime_common_evidence')
            gates.add('owned temporary staging against explicit input hashes; preparation never qualifies runtime, candidate or release')
            reasons.append({'path': path, 'surface': 'common-evidence-preparation'}); continue
        if path == 'scripts/plan-manager-checks.py':
            python.add('scripts.tests.test_manager_check_plan')
            gates.add('review check selection and preserve conservative unknown/shared-input fallback')
            reasons.append({'path': path, 'surface': 'read-only-check-planner'}); continue
        if path.startswith(("scripts/", ".github/")):
            python_full = True; gates.add("changed workflow integration; clean CI is distinct from local tests")
            reasons.append({"path": path, "surface": "workflow"}); continue
        if path in ("AGENTS.md", "README.md", "README.en.md", "CHANGELOG.md", "LICENSE") or path.startswith(("docs/", ".agents/skills/", "releases/")):
            gates.add("review affected claims/links; use semantic documentation contracts where applicable")
            reasons.append({"path": path, "surface": "documentation"}); continue
        full = True; python_full = True
        reasons.append({"path": path, "surface": "shared-or-unknown"})
        gates.add("review shared dependencies and required native/release gates before execution")
    mode = "full" if full else "targeted" if selected else "none"
    swift = ["python3", "-B", "scripts/test-manager-fast.py", "--all"] if full else ["python3", "-B", "scripts/test-manager-fast.py"] + [item for s in sorted(selected) for item in ["--suite", s]] if selected else None
    py = ["python3", "-B", "-m", "unittest", "discover", "-s", "scripts/tests", "-p", "test_*.py"] if python_full else ["python3", "-B", "-m", "unittest", *sorted(python)] if python else None
    return {"schemaVersion": 1, "status": "not-run", "swiftMode": mode, "selectedSuites": [] if full else sorted(selected),
            "commands": [c for c in [swift, py] if c], "reasons": reasons, "requiredAdditionalGates": sorted(gates),
            "releaseSurface": delivery, "releaseGate": False, "boundary": "planning only; no PASS reuse, native launch, secrets, build or deploy"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", default="HEAD")
    parser.add_argument("--path", action="append", help="Explicit relative path; no Git query when supplied")
    args = parser.parse_args()
    try:
        base, paths = (None, args.path) if args.path else changed_paths(args.base)
        report = plan(paths, fast.suites()); report["baseCommit"] = base
    except (ValueError, subprocess.CalledProcessError) as error:
        parser.error("Invalid source selection or baseline")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
