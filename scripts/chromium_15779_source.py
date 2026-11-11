"""Verify the reviewed macOS arm64 source inputs for Chromium 157.0.8103.79."""

import hashlib
import json
from pathlib import Path
import subprocess

VERSION = "157.0.8103.79"
PREFIX = "chromium-15779"
CONTRACT = PREFIX + "-source-contract.json"
PLAN = PREFIX + "-rebase-plan.json"
SOURCE_MODE = "official-chromium-stable-with-reviewed-neantik-port"
UPSTREAM = {
    "repository": "https://chromium.googlesource.com/chromium/src.git",
    "tag": VERSION,
    "commit": "6dc9bc3bdaea5c35ed6d41fceab2f7a3a2227c4f",
    "tree": "76343b515ca111daccb8748d83742c25265a925d",
}
SOURCE = {
    "head": "548d081a08839e902272be2caf92b298081cd988",
    "tree": "852c95983dba3a2f966d58e4ab5c1846b8ce7b5c",
    "sourcePatchSHA256": "3ca33eeb364c3f555b87544da05bc1e3e18b449b4290bb654ef001da89da6a16",
    "changedPaths": 740,
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
    "third_party/skia": "fef60e46c522b87e5802ddf0a215a763dd5e0483",
    "v8": "307108153d1e35e6e74528ee55f97b0cd59bf182",
}
LICENSE_SHA256 = "368cca1106be99d39ecd32a38d8305585d802a475effb66380b91ffc9bcf709b"


def _checked_file(root: Path, relative: str) -> Path:
    path = root / relative
    if path.resolve() != path or not path.is_file():
        raise ValueError(f"Chromium .79 file missing or not canonical: {relative}")
    return path


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


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
    if contract != {
        **common,
        "sourceMode": SOURCE_MODE,
        "status": "source-pins-verified-build-pending",
        "binaryBindingStatus": "pending-build",
        "officialChromiumBase": UPSTREAM,
        "portSource": SOURCE,
        "rebasePlan": f"runtime/{PLAN}",
        "rebasePlanSHA256": _sha256(plan_path),
        "chromiumLicenseSHA256": LICENSE_SHA256,
    }:
        raise ValueError("Chromium .79 pending source contract differs")
    if _sha256(_checked_file(runtime, "licenses/Chromium-LICENSE")) != LICENSE_SHA256:
        raise ValueError("Chromium .79 license digest mismatch")
    return contract


def verify_source_root(source_root: Path, project_root: Path) -> dict:
    contract = verify_contract(project_root)
    if not source_root.is_absolute() or source_root.resolve() != source_root:
        raise ValueError("Chromium .79 source root must be canonical")
    identities = {
        "HEAD": SOURCE["head"],
        "HEAD^{tree}": SOURCE["tree"],
        "HEAD:DEPS": SOURCE["depsBlob"],
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
    if _sha256(_checked_file(source_root, SOURCE["buildArgsPath"])) != SOURCE["buildArgsSHA256"]:
        raise ValueError("Chromium .79 GN args digest mismatch")
    if _sha256(_checked_file(source_root, "LICENSE")) != LICENSE_SHA256:
        raise ValueError("Chromium .79 source license digest mismatch")
    return contract
