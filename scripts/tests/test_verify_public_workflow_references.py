import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "verify-public-workflow-references.py"
SPEC = importlib.util.spec_from_file_location(
    "verify_public_workflow_references",
    SCRIPT,
)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class PublicWorkflowReferenceTests(unittest.TestCase):
    def test_current_public_workflow_dependency_closure_is_complete(self) -> None:
        scanned, references = MODULE.verify_public_workflow_references(
            project_root=ROOT,
        )
        self.assertGreaterEqual(scanned, 20)
        self.assertGreaterEqual(references, 20)

    def test_missing_transitive_script_fails(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "scripts").mkdir()
            entrypoint = root / "scripts" / "entry.sh"
            entrypoint.write_text(
                '#!/bin/sh\n"$PROJECT_ROOT/scripts/missing.py"\n',
                encoding="utf-8",
            )
            entrypoint.chmod(0o755)

            with self.assertRaisesRegex(
                MODULE.PublicWorkflowReferenceError,
                "scripts/missing.py",
            ):
                MODULE.verify_public_workflow_references(
                    project_root=root,
                    entrypoints=("scripts/entry.sh",),
                )

    def test_missing_local_markdown_link_fails(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "docs").mkdir()
            readme = root / "docs" / "README.md"
            readme.write_text("[Missing](MISSING.md)\n", encoding="utf-8")

            with self.assertRaisesRegex(
                MODULE.PublicWorkflowReferenceError,
                "MISSING.md",
            ):
                MODULE.verify_public_workflow_references(
                    project_root=root,
                    entrypoints=("docs/README.md",),
                )

    def test_only_explicit_non_local_placeholders_are_ignored(self) -> None:
        self.assertTrue(
            MODULE.is_explicit_non_local_placeholder(
                "scripts/example-VERSION.py"
            )
        )
        self.assertTrue(
            MODULE.is_explicit_non_local_placeholder(
                "<ABSOLUTE_EXTERNAL_SCRIPT>"
            )
        )
        self.assertFalse(
            MODULE.is_explicit_non_local_placeholder("scripts/missing.py")
        )


if __name__ == "__main__":
    unittest.main()
