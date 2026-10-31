import sys
import tempfile
import unittest
import importlib.util
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(PROJECT_ROOT / "scripts"))
import runtime_source_provenance as provenance
SPEC = importlib.util.spec_from_file_location(
    "chromium_154_source_route",
    PROJECT_ROOT / "scripts" / "chromium-154-source-route.py",
)
assert SPEC is not None and SPEC.loader is not None
route = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(route)


class Chromium154SourceRouteTests(unittest.TestCase):
    def test_m154_route_fails_closed_when_source_contract_is_missing(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            runtime = root / "runtime"
            runtime.mkdir()
            (runtime / "chromium-154-rebase-plan.json").write_text("{}")
            (runtime / "chromium-154-toolchain-lock.json").write_text("{}")

            with self.assertRaisesRegex(
                provenance.SourceProvenanceError,
                "refusing to fall back to M152",
            ):
                route.resolve(root)

    def test_m154_route_returns_only_its_exact_versioned_inputs(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            runtime = root / "runtime"
            runtime.mkdir()
            expected = (
                "chromium-154-source-contract.json",
                "chromium-154-rebase-plan.json",
                "chromium-154-toolchain-lock.json",
            )
            for name in expected:
                (runtime / name).write_text("{}", encoding="utf-8")

            result = route.resolve(root)

            self.assertEqual(
                set(result),
                {"sourceContract", "rebasePlan", "toolchainLock"},
            )
            self.assertEqual(
                {Path(value).name for value in result.values()},
                set(expected),
            )


if __name__ == "__main__":
    unittest.main()
