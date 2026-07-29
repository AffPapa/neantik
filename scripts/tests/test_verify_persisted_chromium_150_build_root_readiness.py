import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


SCRIPT = (
    Path(__file__).resolve().parents[1]
    / "verify-persisted-chromium-150-build-root-readiness.py"
)
SPEC = importlib.util.spec_from_file_location(
    "verify_persisted_chromium_150_build_root_readiness",
    SCRIPT,
)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class PersistedChromium150BuildRootReadinessVerifierTests(unittest.TestCase):
    def test_accepts_fresh_persisted_readiness(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            payload = readiness_payload()
            write_readiness(root, payload)

            with mock.patch.object(MODULE.EXPORTER, "build_readiness", return_value=payload):
                result = MODULE.verify_persisted_readiness(project_root=root)

        self.assertIn("1/2 ready", result)
        self.assertIn("owner storage decision contract", result)

    def test_rejects_stale_json(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            payload = readiness_payload(ready_count=0)
            write_readiness(root, payload)
            current = readiness_payload(ready_count=1)

            with mock.patch.object(MODULE.EXPORTER, "build_readiness", return_value=current):
                with self.assertRaisesRegex(
                    MODULE.PersistedBuildRootReadinessError,
                    "stale",
                ):
                    MODULE.verify_persisted_readiness(project_root=root)

    def test_rejects_stale_markdown(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            payload = readiness_payload()
            write_readiness(root, payload, markdown="old\n")

            with mock.patch.object(MODULE.EXPORTER, "build_readiness", return_value=payload):
                with self.assertRaisesRegex(
                    MODULE.PersistedBuildRootReadinessError,
                    "markdown is stale",
                ):
                    MODULE.verify_persisted_readiness(project_root=root)

    def test_rejects_summary_count_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            payload = readiness_payload()
            payload["summary"]["candidateCount"] = 99
            write_readiness(root, payload)

            with mock.patch.object(MODULE.EXPORTER, "build_readiness", return_value=payload):
                with self.assertRaisesRegex(
                    MODULE.PersistedBuildRootReadinessError,
                    "candidateCount",
                ):
                    MODULE.verify_persisted_readiness(project_root=root)

    def test_rejects_missing_owner_decision_contract(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            payload = readiness_payload()
            del payload["ownerDecisionContract"]
            write_readiness(root, payload, markdown="old\n")

            with mock.patch.object(MODULE.EXPORTER, "build_readiness", return_value=payload):
                with self.assertRaisesRegex(
                    MODULE.PersistedBuildRootReadinessError,
                    "ownerDecisionContract",
                ):
                    MODULE.verify_persisted_readiness(project_root=root)

    def test_rejects_missing_owner_build_root_input_template(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            payload = readiness_payload()
            del payload["ownerBuildRootInputTemplate"]
            write_readiness(root, payload, markdown="old\n")

            with mock.patch.object(MODULE.EXPORTER, "build_readiness", return_value=payload):
                with self.assertRaisesRegex(
                    MODULE.PersistedBuildRootReadinessError,
                    "ownerBuildRootInputTemplate",
                ):
                    MODULE.verify_persisted_readiness(project_root=root)

    def test_rejects_unsafe_owner_build_root_input_template(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            payload = readiness_payload()
            payload["ownerBuildRootInputTemplate"]["safetyBoundary"] = ["safe enough"]
            write_readiness(root, payload, markdown="old\n")

            with mock.patch.object(MODULE.EXPORTER, "build_readiness", return_value=payload):
                with self.assertRaisesRegex(
                    MODULE.PersistedBuildRootReadinessError,
                    "safetyBoundary",
                ):
                    MODULE.verify_persisted_readiness(project_root=root)


def readiness_payload(*, ready_count: int = 1) -> dict:
    candidates = [
        {
            "buildRoot": "/private/tmp/nevision-chromium-150",
            "ready": ready_count > 0,
            "status": "ready" if ready_count > 0 else "blocked",
        },
        {
            "buildRoot": "/Volumes/NeAntikBuild/nevision-chromium-150",
            "ready": False,
            "status": "not-mounted",
        },
    ]
    return {
        "schemaVersion": 1,
        "generatedAt": "2026-07-26T00:00:00+00:00",
        "mode": "chromium-150-build-root-readiness",
        "targetChromiumVersion": "150.0.7871.186",
        "minimumPrepareFreeGiB": 55,
        "preservedEvidenceBuildRoot": "/private/tmp/nevision-chromium-build-20260725",
        "releaseBoundary": "This report is read-only and local-only.",
        "summary": {
            "candidateCount": len(candidates),
            "readyCount": ready_count,
            "hasReadyBuildRoot": ready_count > 0,
            "recommendedBuildRoot": candidates[0]["buildRoot"] if ready_count > 0 else None,
        },
        "ownerDecisionContract": {
            "status": "owner-storage-decision-required",
            "requiredFreeGiB": 55,
            "recommendedExternalVolume": "/Volumes/NeAntikBuild",
            "recommendedExternalBuildRoot": "/Volumes/NeAntikBuild/nevision-chromium-150",
            "preservedEvidenceBuildRoot": "/private/tmp/nevision-chromium-build-20260725",
            "acceptedChoices": [
                "Mount an external APFS volume at /Volumes/NeAntikBuild with at least 55 GiB free.",
            ],
            "commands": [
                "scripts/preflight-runtime-rebase-150.py /Volumes/NeAntikBuild/nevision-chromium-150",
            ],
            "prohibitedActions": [
                "Do not delete or mutate the preserved Chromium 144 evidence root.",
            ],
            "releaseBoundary": (
                "This contract does not mount disks, delete files, clone Chromium, "
                "apply patches, build, sign, notarize, or publish."
            ),
        },
        "ownerBuildRootInputTemplate": {
            "target": "owner-shell-environment",
            "format": "shell-env-template",
            "placeholdersMustBeReplaced": ["<ABSOLUTE_CHROMIUM_150_BUILD_ROOT>"],
            "requiredEnvironment": [
                'export NEANTIK_CHROMIUM_150_BUILD_ROOT="<ABSOLUTE_CHROMIUM_150_BUILD_ROOT>"',
            ],
            "defaultRecommendedValue": "/Volumes/NeAntikBuild/nevision-chromium-150",
            "validationRules": [
                "Value must be an absolute path.",
                "Path must not equal preserved evidence build root /private/tmp/nevision-chromium-build-20260725.",
                "Path must have at least 55 GiB free before bootstrap.",
                "Prefer a dedicated external APFS volume such as /Volumes/NeAntikBuild.",
                "Run preflight before bootstrap and after source extraction.",
            ],
            "applyThenVerify": [
                'python3 scripts/export-chromium-150-build-root-readiness.py --candidate-root "$NEANTIK_CHROMIUM_150_BUILD_ROOT"',
                'python3 scripts/preflight-runtime-rebase-150.py "$NEANTIK_CHROMIUM_150_BUILD_ROOT"',
                'python3 scripts/preflight-runtime-rebase-150.py --json "$NEANTIK_CHROMIUM_150_BUILD_ROOT"',
                'python3 scripts/generate-runtime-rebase-150-bootstrap.py "$NEANTIK_CHROMIUM_150_BUILD_ROOT" --output dist/NeAntik-Chromium-150-bootstrap.sh',
                "bash dist/NeAntik-Chromium-150-bootstrap.sh",
                'python3 scripts/preflight-runtime-rebase-150.py "$NEANTIK_CHROMIUM_150_BUILD_ROOT" --source-root "$NEANTIK_CHROMIUM_150_BUILD_ROOT/build/src"',
            ],
            "safetyBoundary": [
                "Do not set NEANTIK_CHROMIUM_150_BUILD_ROOT to the preserved Chromium 144 evidence root.",
                "Do not delete or mutate preserved evidence to create free space.",
                "Do not use shell globs, unresolved variables, or broad directories as build roots.",
                "Do not run bootstrap until the selected build root passes preflight.",
                "Do not mark Chromium 150 patches ported from this template alone.",
            ],
        },
        "candidates": candidates,
        "nextSteps": ["Choose a candidate whose ready=true."],
    }


def write_readiness(root: Path, payload: dict, *, markdown: str | None = None) -> None:
    dist = root / "dist"
    dist.mkdir(parents=True)
    (dist / "NeAntik-Chromium-150-build-root-readiness.json").write_text(
        json.dumps(payload, indent=2) + "\n",
        encoding="utf-8",
    )
    if markdown is None:
        markdown = MODULE.EXPORTER.format_markdown(payload)
    (dist / "NeAntik-Chromium-150-build-root-readiness.md").write_text(
        markdown,
        encoding="utf-8",
    )


if __name__ == "__main__":
    unittest.main()
