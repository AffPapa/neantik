import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "preflight-runtime-rebase-150.py"
SPEC = importlib.util.spec_from_file_location("preflight_runtime_rebase_150", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


MAC_COMMIT = "9cbd94c2b8f6f2a58a80bf32b3e01b68f3d129d4"
COMMON_COMMIT = "fd0378e4f20fa09e21b09beca71573d435d787cf"


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value), encoding="utf-8")


def plan(root: Path, preserved: str | None = None, target: str = "150.0.7871.186") -> Path:
    path = root / "runtime" / "chromium-150-rebase-plan.json"
    write_json(
        path,
        {
            "schemaVersion": 1,
            "targetChromiumVersion": target,
            "minimumPrepareFreeGiB": 55,
            "preservedEvidenceBuildRoot": preserved or str(root / "old-144"),
            "macPackaging": {
                "repository": "https://github.com/ungoogled-software/ungoogled-chromium-macos.git",
                "commit": MAC_COMMIT,
                "packagedChromiumVersion": "150.0.7871.181",
            },
            "commonChromium": {
                "repository": "https://github.com/ungoogled-software/ungoogled-chromium.git",
                "tag": "150.0.7871.186-1",
                "commit": COMMON_COMMIT,
            },
        },
    )
    return path


def baseline(root: Path, minimum: str = "150.0.7871.186") -> Path:
    path = root / "runtime" / "security-baseline.json"
    write_json(
        path,
        {
            "schemaVersion": 1,
            "minimumPublicChromiumVersion": minimum,
        },
    )
    return path


def git_repo(path: Path, commit: str) -> None:
    path.mkdir(parents=True, exist_ok=True)
    subprocess.run(["git", "init", "-q"], cwd=path, check=True)
    subprocess.run(["git", "config", "user.email", "test@example.com"], cwd=path, check=True)
    subprocess.run(["git", "config", "user.name", "Test"], cwd=path, check=True)
    (path / "file.txt").write_text(commit, encoding="utf-8")
    subprocess.run(["git", "add", "file.txt"], cwd=path, check=True)
    subprocess.run(
        [
            "git",
            "commit",
            "-q",
            f"--date=2026-07-25T00:00:00Z",
            "-m",
            "fixture",
        ],
        cwd=path,
        env={**dict(), **{"GIT_AUTHOR_DATE": "2026-07-25T00:00:00Z", "GIT_COMMITTER_DATE": "2026-07-25T00:00:00Z"}},
        check=True,
    )


def write_source_version(source_root: Path, version: str) -> None:
    major, minor, build, patch = version.split(".")
    version_path = source_root / "chrome" / "VERSION"
    version_path.parent.mkdir(parents=True)
    version_path.write_text(
        "\n".join(
            [
                f"MAJOR={major}",
                f"MINOR={minor}",
                f"BUILD={build}",
                f"PATCH={patch}",
                "",
            ]
        ),
        encoding="utf-8",
    )


class RuntimeRebase150PreflightTests(unittest.TestCase):
    def test_blocks_when_free_space_is_too_low(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with self.assertRaisesRegex(MODULE.RebasePreflightError, "55 GiB"):
                MODULE.verify(
                    plan_path=plan(root),
                    baseline_path=baseline(root),
                    build_root=root / "build-150",
                    free_gib=12,
                )

    def test_blocks_preserved_evidence_root(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            preserved = root / "old-144"
            with self.assertRaisesRegex(MODULE.RebasePreflightError, "preserved"):
                MODULE.verify(
                    plan_path=plan(root, str(preserved)),
                    baseline_path=baseline(root),
                    build_root=preserved,
                    free_gib=80,
                )

    def test_blocks_target_below_security_baseline(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with self.assertRaisesRegex(MODULE.RebasePreflightError, "below security baseline"):
                MODULE.verify(
                    plan_path=plan(root, target="149.0.1.1"),
                    baseline_path=baseline(root),
                    build_root=root / "build-150",
                    free_gib=80,
                )

    def test_accepts_empty_safe_root_with_enough_space(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            result = MODULE.verify(
                plan_path=plan(root),
                baseline_path=baseline(root),
                build_root=root / "build-150",
                free_gib=80,
            )
        self.assertIn("Chromium 150 rebase preflight passed", result)

    def test_rejects_non_empty_non_git_root(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            build_root = root / "build-150"
            build_root.mkdir()
            (build_root / "stray.txt").write_text("x", encoding="utf-8")
            with self.assertRaisesRegex(MODULE.RebasePreflightError, "non-empty"):
                MODULE.verify(
                    plan_path=plan(root),
                    baseline_path=baseline(root),
                    build_root=build_root,
                    free_gib=80,
                )

    def test_json_report_exposes_machine_readable_contract(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            report = MODULE.verify_report(
                plan_path=plan(root),
                baseline_path=baseline(root),
                build_root=root / "build-150",
                free_gib=80,
            )

        self.assertTrue(report["ok"])
        self.assertEqual(report["targetChromiumVersion"], "150.0.7871.186")
        self.assertEqual(report["minimumPrepareFreeGiB"], 55)
        self.assertEqual(report["freeGiB"], 80)
        self.assertFalse(report["preservedEvidenceBuildRootTouched"])
        source = report["sourceRoot"]
        self.assertIsInstance(source, dict)
        self.assertEqual(source["state"], "not-present-yet")

    def test_cli_json_failure_is_parseable(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            plan(root)
            baseline(root)

            completed = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--project-root",
                    str(root),
                    "--free-gib",
                    "12",
                    "--json",
                    str(root / "build-150"),
                ],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

        self.assertNotEqual(completed.returncode, 0)
        payload = json.loads(completed.stdout)
        self.assertFalse(payload["ok"])
        self.assertIn("55 GiB", payload["error"])
        self.assertEqual(completed.stderr, "")

    def test_verifies_explicit_chromium_source_root_version(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source_root = root / "build-150" / "build" / "src"
            write_source_version(source_root, "150.0.7871.186")
            (root / "build-150" / ".git").mkdir()
            report = MODULE.verify_report(
                plan_path=plan(root),
                baseline_path=baseline(root),
                build_root=root / "build-150",
                source_root=source_root,
                free_gib=80,
            )

        source = report["sourceRoot"]
        self.assertTrue(source["versionVerified"])
        self.assertEqual(source["chromiumVersion"], "150.0.7871.186")
        self.assertEqual(source["state"], "verified")

    def test_rejects_explicit_chromium_source_root_version_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source_root = root / "build-150" / "build" / "src"
            write_source_version(source_root, "149.0.1.1")
            (root / "build-150" / ".git").mkdir()
            with self.assertRaisesRegex(MODULE.RebasePreflightError, "expected 150.0.7871.186"):
                MODULE.verify_report(
                    plan_path=plan(root),
                    baseline_path=baseline(root),
                    build_root=root / "build-150",
                    source_root=source_root,
                    free_gib=80,
                )


if __name__ == "__main__":
    unittest.main()
