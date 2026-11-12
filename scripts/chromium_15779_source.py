"""Verify the reviewed macOS arm64 source inputs for Chromium 157.0.8103.79."""

import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess

VERSION = "157.0.8103.79"
PREFIX = "chromium-15779"
CONTRACT = PREFIX + "-source-contract.json"
PLAN = PREFIX + "-rebase-plan.json"
BUILD_EVIDENCE = PREFIX + "-build-evidence.json"
SOURCE_MODE = "official-chromium-stable-with-reviewed-neantik-port"
UPSTREAM = {
    "repository": "https://chromium.googlesource.com/chromium/src.git",
    "tag": VERSION,
    "commit": "6dc9bc3bdaea5c35ed6d41fceab2f7a3a2227c4f",
    "tree": "76343b515ca111daccb8748d83742c25265a925d",
}
SOURCE = {
    "head": "1fd25723d80d6394df3189b87937132335e2d807",
    "tree": "aef776c3456fb06cf5590aaab35542230ee590b2",
    "sourcePatchSHA256": "6f5310590748542c053f86421fcc6ba6a1e3ee98ee822ab78864135ebc87b7dd",
    "changedPaths": 763,
    "skiaPrivacy": {
        "base": "fef60e46c522b87e5802ddf0a215a763dd5e0483",
        "tree": "36114a5bd4ff36ff582f5b5dd81298b3418e2e76",
        "patchSHA256": "806d24e15c204fe84e9b5d423f64a0f280a8c0b33722dc3a2b847650ecf96513",
    },
    "depsBlob": "5a1b6829a2cdef9a993cb9cc49a49ebc7ecb300a",
    "buildArgsPath": "out/NeAntik15779/args.gn",
    "buildArgsSHA256": "8c013d5d2cbc3372f13e38d2220c6a698d13dd8dd7a0ed853197f21af253d46e",
    "buildOutputDirectory": "out/NeAntik15779",
}
CHANGED_DEPENDENCIES = {
    "third_party/angle": "c56e2a4a9b8cb0040920c995a268be559ba53f1c",
    "third_party/dawn": "106245fa2b9e1cf8b59b1bb8e010af3c7ca8b600",
    "third_party/devtools-frontend/src": "6f9a57d502c857e2412a57fe03c96286d7877479",
    "third_party/icu": "c670d124c9b6aa92c0b492cf543808300e0e6103",
    "third_party/skia": "a3057a2925536fdd467e3b1b9f5f9f01b239ec85",
    "v8": "307108153d1e35e6e74528ee55f97b0cd59bf182",
}
LICENSE_SHA256 = "368cca1106be99d39ecd32a38d8305585d802a475effb66380b91ffc9bcf709b"


def _checked_file(root: Path, relative: str) -> Path:
    path = root / relative
    if path.resolve() != path or not path.is_file():
        raise ValueError(f"Chromium .79 file missing or not canonical: {relative}")
    return path


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _is_sha256(value) -> bool:
    return isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value) is not None


def _git(root: Path, *args: str) -> str:
    result = subprocess.run(["git", "-C", str(root), *args], capture_output=True, text=True)
    if result.returncode:
        raise ValueError(f"Chromium .79 Git verification failed: {args[0]}")
    return result.stdout.strip()


def verify_contract(project_root: Path) -> dict:
    runtime = project_root.resolve() / "runtime"
    plan_path = _checked_file(runtime, PLAN)
    contract = json.loads(_checked_file(runtime, CONTRACT).read_text())
    plan = json.loads(plan_path.read_text())
    for document in (contract, plan):
        if (not isinstance(document, dict) or type(document.get("schemaVersion")) is not int
                or document.get("releaseReady") is not False):
            raise ValueError("Chromium .79 source documents must remain unqualified")
    common = {
        "schemaVersion": 1,
        "targetChromiumVersion": VERSION,
        "targetArchitecture": "arm64",
        "releaseReady": False,
    }
    if any(type(plan.get(field)) is not int for field in ("buildJobs", "macThinLTOJobs")) or plan != {
        **common,
        "officialChromiumBase": UPSTREAM,
        "portSource": SOURCE,
        "changedDependencyPins": CHANGED_DEPENDENCIES,
        "ninjaTarget": "chrome",
        "buildJobs": 1,
        "macThinLTOJobs": 1,
    }:
        raise ValueError("Chromium .79 source or build plan pins differ")
    expected = {
        **common,
        "sourceMode": SOURCE_MODE,
        "status": "source-pins-verified-build-pending",
        "binaryBindingStatus": "pending-build",
        "officialChromiumBase": UPSTREAM,
        "portSource": SOURCE,
        "rebasePlan": f"runtime/{PLAN}",
        "rebasePlanSHA256": _sha256(plan_path),
        "chromiumLicenseSHA256": LICENSE_SHA256,
    }
    if contract.get("binaryBindingStatus") == "pending-runtime-report":
        evidence_path = _checked_file(runtime, BUILD_EVIDENCE)
        baseline = contract.get("securityBaselineSHA256")
        if not _is_sha256(baseline):
            raise ValueError("Chromium .79 security baseline digest missing")
        baseline_path = _checked_file(runtime, "security-baseline.json")
        if _sha256(baseline_path) != baseline:
            baseline_path = _checked_file(runtime, f"security-baselines/{baseline}.json")
        if _sha256(baseline_path) != baseline:
            raise ValueError("Chromium .79 security baseline digest mismatch")
        expected.update(status="build-complete-runtime-report-pending",
                        binaryBindingStatus="pending-runtime-report",
                        buildEvidenceFile=f"runtime/{BUILD_EVIDENCE}",
                        buildEvidenceSHA256=_sha256(evidence_path),
                        securityBaselineSHA256=baseline)
        _validate_build_evidence(json.loads(evidence_path.read_text()))
    if contract != expected:
        raise ValueError("Chromium .79 source contract differs")
    if _sha256(_checked_file(runtime, "licenses/Chromium-LICENSE")) != LICENSE_SHA256:
        raise ValueError("Chromium .79 license digest mismatch")
    return contract


def _validate_build_evidence(evidence: dict) -> None:
    required = {
        "schemaVersion": 1,
        "status": "chromium-source-build-succeeded-unqualified",
        "chromiumVersion": VERSION,
        "targetArchitecture": "arm64",
        "officialCommit": UPSTREAM["commit"],
        "officialTree": UPSTREAM["tree"],
        "portHead": SOURCE["head"],
        "portTree": SOURCE["tree"],
        "sourcePatchSHA256": SOURCE["sourcePatchSHA256"],
        "buildConfigurationSHA256": SOURCE["buildArgsSHA256"],
        "buildOutputDirectory": SOURCE["buildOutputDirectory"],
        "ninjaTarget": "chrome",
        "ninjaExitCode": 0,
        "releaseReady": False,
    }
    hashes = ("buildLogSHA256", "ninjaLogSHA256", "browserExecutableSHA256", "frameworkSHA256",
              "signingInputsSHA256")
    counts = ("ninjaActionsCompleted", "ninjaActionsExpected")
    if (not isinstance(evidence, dict) or set(evidence) != set(required) | set(hashes) | set(counts)
            or any(type(evidence[key]) is not type(value) or evidence[key] != value for key, value in required.items())
            or not all(_is_sha256(evidence[key]) for key in hashes)
            or not all(type(evidence[key]) is int and evidence[key] > 0 for key in counts)
            or evidence[counts[0]] != evidence[counts[1]]):
        raise ValueError("Chromium .79 exact completed build evidence is invalid")


def verify_source_root(source_root: Path, project_root: Path) -> dict:
    contract = verify_contract(project_root)
    if not source_root.is_absolute() or source_root.resolve() != source_root:
        raise ValueError("Chromium .79 source root must be canonical")
    identities = {
        "HEAD": SOURCE["head"],
        "HEAD^{tree}": SOURCE["tree"],
        "HEAD:DEPS": SOURCE["depsBlob"],
        "HEAD:third_party/skia": CHANGED_DEPENDENCIES["third_party/skia"],
        UPSTREAM["commit"] + "^{tree}": UPSTREAM["tree"],
    }
    for selector, expected in identities.items():
        if _git(source_root, "rev-parse", selector) != expected:
            raise ValueError(f"Chromium .79 Git object differs: {selector}")
    _git(source_root, "merge-base", "--is-ancestor", UPSTREAM["commit"], "HEAD")
    _git(source_root, "diff", "--quiet", "--ignore-submodules=all", "HEAD", "--")
    for relative, expected in CHANGED_DEPENDENCIES.items():
        checkout = source_root / relative
        if (checkout.resolve() != checkout or _git(checkout, "rev-parse", "--show-toplevel") != str(checkout)
                or _git(checkout, "rev-parse", "HEAD") != expected):
            raise ValueError(f"Chromium .79 dependency differs: {relative}")
        _git(checkout, "diff", "--quiet", "HEAD", "--")
    skia = source_root / "third_party/skia"
    skia_port = SOURCE["skiaPrivacy"]
    if _git(skia, "rev-parse", "HEAD^{tree}") != skia_port["tree"]:
        raise ValueError("Chromium .79 Skia privacy tree differs")
    patch = subprocess.run(
        ["git", "-C", str(skia), "diff", "--binary", "--full-index", skia_port["base"], "HEAD"],
        capture_output=True,
    )
    if patch.returncode or hashlib.sha256(patch.stdout).hexdigest() != skia_port["patchSHA256"]:
        raise ValueError("Chromium .79 Skia privacy patch differs")
    dnr = _checked_file(source_root, "extensions/browser/api/declarative_net_request/utils.cc")
    cleanup = json.loads(_checked_file(project_root.resolve(), "Resources/SiteProtection/query-rules.json").read_text())
    if len(cleanup) != 1 or f'R"NEANTIK({cleanup[0]["condition"]["regexFilter"]})NEANTIK"' not in dnr.read_text():
        raise ValueError("Packaged query cleanup does not match the bounded M157 regex")
    if _sha256(_checked_file(source_root, SOURCE["buildArgsPath"])) != SOURCE["buildArgsSHA256"]:
        raise ValueError("Chromium .79 GN args digest mismatch")
    if _sha256(_checked_file(source_root, "LICENSE")) != LICENSE_SHA256:
        raise ValueError("Chromium .79 source license digest mismatch")
    return contract


def _completed(project_root: Path) -> tuple[dict, dict]:
    contract = verify_contract(project_root)
    if contract["binaryBindingStatus"] != "pending-runtime-report":
        raise ValueError("Chromium .79 source is pinned and awaits exact completed build evidence")
    evidence = json.loads(_checked_file(project_root.resolve() / "runtime", BUILD_EVIDENCE).read_text())
    return contract, evidence


def _provenance(contract: dict, evidence: dict, project_root: Path) -> dict:
    return {
        "schemaVersion": 1,
        "status": "source-qualified",
        "sourceMode": SOURCE_MODE,
        "targetChromiumVersion": VERSION,
        "targetArchitecture": "arm64",
        "officialChromiumBase": UPSTREAM,
        "sourceContractSHA256": _sha256(project_root.resolve() / "runtime" / CONTRACT),
        "sourceHead": SOURCE["head"],
        "sourceTree": SOURCE["tree"],
        "sourcePatchSHA256": SOURCE["sourcePatchSHA256"],
        "buildArgsSHA256": SOURCE["buildArgsSHA256"],
        "buildEvidenceSHA256": contract["buildEvidenceSHA256"],
        "buildEvidence": evidence,
        "sourceChecks": {
            "officialCommitTree": "verified",
            "changedDependencyPins": "verified",
            "reviewedPortTree": "verified",
            "buildArgs": "verified",
            "buildEvidence": "verified",
        },
        "binaryBinding": {"status": "pending-runtime-report", "requiredEvidence": "schema-3-runtime-report"},
        "releaseReady": False,
    }


def build_provenance(source_root: Path, project_root: Path) -> dict:
    contract, evidence = _completed(project_root)
    verify_source_root(source_root, project_root)
    out = source_root / SOURCE["buildOutputDirectory"]
    if _sha256(_checked_file(out, ".ninja_log")) != evidence["ninjaLogSHA256"]:
        raise ValueError("Chromium .79 Ninja log differs from completed build evidence")
    _verify_app(out / "NeAntik Browser.app", out, evidence)
    _verify_signing_inputs(out, evidence)
    return _provenance(contract, evidence, project_root)


def verify_provenance(provenance: dict, project_root: Path) -> None:
    contract, evidence = _completed(project_root)
    if provenance != _provenance(contract, evidence, project_root) or provenance.get("releaseReady") is not False:
        raise ValueError("Chromium .79 provenance differs from exact build evidence")


def _lock(project_root: Path, provenance_sha: str) -> dict:
    contract, _ = _completed(project_root)
    runtime = project_root.resolve() / "runtime"
    if not _is_sha256(provenance_sha):
        raise ValueError("Chromium .79 source provenance SHA-256 is invalid")
    return {
        "schemaVersion": 4,
        "status": "source-qualified",
        "targetArchitecture": "arm64",
        "sourceContractSHA256": _sha256(runtime / CONTRACT),
        "sourceProvenanceSHA256": provenance_sha,
        "fingerprintChromium": {**UPSTREAM, "chromiumVersion": VERSION, "licenseSHA256": LICENSE_SHA256},
        "ownedInputs": {
            "sourcePatchSHA256": SOURCE["sourcePatchSHA256"],
            "buildArgsSHA256": SOURCE["buildArgsSHA256"],
        },
        "ownedManifests": {
            "neantikPatchSeriesSHA256": _sha256(runtime / "nevision-patches/series.json"),
            "appleDeviceTuplesSHA256": _sha256(runtime / "apple-device-tuples.json"),
            "securityBaselineSHA256": contract["securityBaselineSHA256"],
        },
        "binaryBinding": {
            "status": "not-attested-by-this-document",
            "requiredEvidence": "schema-3-runtime-report",
            "policy": "This source-only lock makes no runtime, signing, notarization, publication or release claim.",
        },
    }


def verify_lock_contract(lock: dict, project_root: Path) -> None:
    if lock != _lock(project_root, lock.get("sourceProvenanceSHA256")):
        raise ValueError("Chromium .79 lock is stale or mutated")


def expected_lock(provenance_path: Path, project_root: Path) -> dict:
    if provenance_path.is_symlink() or not provenance_path.is_file():
        raise ValueError("Chromium .79 provenance file is missing or unsafe")
    verify_provenance(json.loads(provenance_path.read_text()), project_root)
    return _lock(project_root, _sha256(provenance_path))


def verify_lock(lock: dict, provenance_path: Path, project_root: Path) -> dict:
    if lock != expected_lock(provenance_path, project_root):
        raise ValueError("Chromium .79 lock is stale or mutated")
    return lock


def _app_hashes(app: Path, out: Path) -> dict[str, str]:
    if app != out / "NeAntik Browser.app" or app.resolve() != app:
        raise ValueError("Expected the exact Chromium .79 GN output app")
    plist = _checked_file(app, "Contents/Info.plist")
    info = plistlib.loads(plist.read_bytes())
    if info.get("CFBundleShortVersionString") != VERSION or info.get("CFBundleExecutable") != "NeAntik Browser":
        raise ValueError("Chromium .79 app plist identity mismatch")
    framework = f"NeAntik Browser Framework.framework/Versions/{VERSION}/NeAntik Browser Framework"
    files = (
        (_checked_file(app, "Contents/MacOS/NeAntik Browser"), "browserExecutableSHA256"),
        (_checked_file(out, framework), "frameworkSHA256"),
        (_checked_file(app, f"Contents/Frameworks/{framework}"), "frameworkSHA256"),
    )
    hashes = {}
    for path, field in files:
        result = subprocess.run(["/usr/bin/lipo", "-verify_arch", "arm64", path], capture_output=True)
        if result.returncode:
            raise ValueError(f"Chromium .79 output is not arm64: {field}")
        digest = _sha256(path)
        if field in hashes and hashes[field] != digest:
            raise ValueError("Chromium .79 staged framework differs from the linked framework")
        hashes[field] = digest
    return hashes


def _verify_app(app: Path, out: Path, evidence: dict) -> None:
    if any(evidence.get(key) != value for key, value in _app_hashes(app, out).items()):
        raise ValueError("Chromium .79 unsigned outputs differ from build evidence")


def _signing_inputs(out: Path) -> str:
    root = out / "NeAntik Browser Packaging"
    _checked_file(root, "signing/build_props_config.py")
    _checked_file(root, "sign_chrome.py")
    inventory = []
    for path in sorted(root.rglob("*")):
        if path.is_symlink() or not (path.is_dir() or path.is_file()):
            raise ValueError("Chromium .79 signing tree contains an unsafe entry")
        if path.is_file():
            inventory.append((path.relative_to(root).as_posix(), path.stat().st_mode & 0o777, _sha256(path)))
    return hashlib.sha256(json.dumps(inventory, separators=(",", ":")).encode()).hexdigest()


def _verify_signing_inputs(out: Path, evidence: dict) -> None:
    if _signing_inputs(out) != evidence["signingInputsSHA256"]:
        raise ValueError("Chromium .79 signing inputs differ from build evidence")


def verify_unsigned_app(app: Path, args: Path, provenance_path: Path, project_root: Path) -> None:
    _, evidence = _completed(project_root)
    expected_lock(provenance_path, project_root)
    if not args.is_absolute() or args.resolve() != args or args.parts[-3:] != ("out", "NeAntik15779", "args.gn"):
        raise ValueError("Expected exact Chromium .79 GN args path")
    if _sha256(args) != SOURCE["buildArgsSHA256"]:
        raise ValueError("Chromium .79 GN args digest mismatch")
    _verify_app(app, args.parent, evidence)
    _verify_signing_inputs(args.parent, evidence)


def _terminal_actions(log: bytes) -> int:
    last = None
    saw_chrome_verifier = False
    for line in log.splitlines():
        if line.startswith((b"FAILED:", b"ninja: build stopped", b"ninja: error:")):
            raise ValueError("Chromium .79 build log contains a failure")
        match = re.match(rb"^\[(\d+)/(\d+)\]\s+(.+)$", line)
        if match:
            last = match
            saw_chrome_verifier |= b"//chrome:verify_libraries_chrome_app(" in match[3]
    if last is None or int(last[1]) < 1 or last[1] != last[2] or not saw_chrome_verifier:
        raise ValueError("Chromium .79 build log lacks the completed chrome target action")
    return int(last[1])


def capture_build_evidence(source_root: Path, project_root: Path, log: Path, exit_code: int) -> dict:
    """Capture outputs after the watched Ninja invocation and signing-copy target finish."""
    if type(exit_code) is not int or exit_code != 0:
        raise ValueError("Chromium .79 Ninja did not exit successfully")
    if not log.is_absolute() or log.parent != source_root.parent or log.resolve() != log or not log.is_file():
        raise ValueError("Use the watched Ninja transcript from the exact build root")
    transcript = log.read_bytes()
    actions = _terminal_actions(transcript)
    verify_source_root(source_root, project_root)
    out = source_root / SOURCE["buildOutputDirectory"]
    evidence = {
        "schemaVersion": 1,
        "status": "chromium-source-build-succeeded-unqualified",
        "chromiumVersion": VERSION,
        "targetArchitecture": "arm64",
        "officialCommit": UPSTREAM["commit"],
        "officialTree": UPSTREAM["tree"],
        "portHead": SOURCE["head"],
        "portTree": SOURCE["tree"],
        "sourcePatchSHA256": SOURCE["sourcePatchSHA256"],
        "buildConfigurationSHA256": SOURCE["buildArgsSHA256"],
        "buildOutputDirectory": SOURCE["buildOutputDirectory"],
        "ninjaTarget": "chrome",
        "ninjaExitCode": exit_code,
        "ninjaActionsCompleted": actions,
        "ninjaActionsExpected": actions,
        "buildLogSHA256": hashlib.sha256(transcript).hexdigest(),
        "ninjaLogSHA256": _sha256(_checked_file(out, ".ninja_log")),
        **_app_hashes(out / "NeAntik Browser.app", out),
        "signingInputsSHA256": _signing_inputs(out),
        "releaseReady": False,
    }
    _validate_build_evidence(evidence)
    return evidence
