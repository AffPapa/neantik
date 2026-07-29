import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "generate-runtime-rebase-150-bootstrap.py"
SPEC = importlib.util.spec_from_file_location("generate_runtime_rebase_150_bootstrap", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


MAC_COMMIT = "9cbd94c2b8f6f2a58a80bf32b3e01b68f3d129d4"
COMMON_COMMIT = "fd0378e4f20fa09e21b09beca71573d435d787cf"


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value), encoding="utf-8")


def write_project(root: Path) -> None:
    write_json(
        root / "runtime" / "chromium-150-rebase-plan.json",
        {
            "schemaVersion": 1,
            "targetChromiumVersion": "150.0.7871.186",
            "minimumPrepareFreeGiB": 55,
            "preservedEvidenceBuildRoot": str(root / "old-144"),
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
    write_json(
        root / "runtime" / "security-baseline.json",
        {"schemaVersion": 1, "minimumPublicChromiumVersion": "150.0.7871.186"},
    )


class RuntimeRebase150BootstrapTests(unittest.TestCase):
    def test_blocks_generation_when_preflight_fails(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            write_project(root)
            output = root / "dist" / "bootstrap.sh"

            with self.assertRaisesRegex(MODULE.PREFLIGHT.RebasePreflightError, "55 GiB"):
                MODULE.generate(
                    project_root=root,
                    build_root=root / "build-150",
                    output=output,
                    free_gib=12,
                )

            self.assertFalse(output.exists())

    def test_generates_pinned_non_destructive_bootstrap_script(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            write_project(root)
            output = root / "dist" / "bootstrap.sh"

            result = MODULE.generate(
                project_root=root,
                build_root=root / "build-150",
                output=output,
                free_gib=80,
            )

            script = output.read_text(encoding="utf-8")
            self.assertIn("Bootstrap script written", result)
            self.assertIn(MAC_COMMIT, script)
            self.assertIn(COMMON_COMMIT, script)
            self.assertIn("150.0.7871.186-1", script)
            self.assertIn("preflight-runtime-rebase-150.py", script)
            self.assertIn("verify-nevision-patchset-manifest.py", script)
            self.assertIn("verify-runtime-security-reference.py", script)
            self.assertIn('--source-root "$BUILD_ROOT/build/src"', script)
            self.assertIn('against "$BUILD_ROOT/build/src"', script)
            self.assertNotIn('--source-root "$BUILD_ROOT/ungoogled-chromium"', script)
            self.assertIn("git clone", script)
            self.assertNotIn("rm -rf", script)
            self.assertNotIn("git reset --hard", script)
            self.assertTrue(output.stat().st_mode & 0o111)

    def test_rejects_preserved_evidence_root(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            write_project(root)
            output = root / "dist" / "bootstrap.sh"

            with self.assertRaisesRegex(MODULE.PREFLIGHT.RebasePreflightError, "preserved"):
                MODULE.generate(
                    project_root=root,
                    build_root=root / "old-144",
                    output=output,
                    free_gib=80,
                )


if __name__ == "__main__":
    unittest.main()
