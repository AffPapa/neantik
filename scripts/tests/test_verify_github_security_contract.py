from __future__ import annotations

import importlib.util
import tempfile
import unittest
from pathlib import Path


SCRIPT = (
    Path(__file__).resolve().parents[1]
    / "verify-github-security-contract.py"
)
SPEC = importlib.util.spec_from_file_location(
    "verify_github_security_contract",
    SCRIPT,
)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class GitHubSecurityContractTests(unittest.TestCase):
    def fixture(self, *, revision: str) -> Path:
        root = Path(tempfile.mkdtemp(prefix="neantik-github-contract-"))
        workflows = root / ".github" / "workflows"
        workflows.mkdir(parents=True)
        (workflows / "ci.yml").write_text(
            "permissions:\n  contents: read\n"
            f"jobs:\n  test:\n    steps:\n      - uses: owner/action@{revision}\n",
            encoding="utf-8",
        )
        (workflows / "codeql.yml").write_text(
            "permissions:\n  contents: read\n"
            "jobs:\n  security:\n    permissions:\n"
            "      security-events: write\n    steps:\n"
            f"      - uses: github/codeql-action/init@{revision}\n"
            "        with:\n          languages: swift\n"
            "          build-mode: manual\n"
            f"      - uses: github/codeql-action/analyze@{revision}\n"
            "        with:\n          languages: python\n"
            "          build-mode: none\n"
            "      - run: ./scripts/verify-native-swift-release.sh\n",
            encoding="utf-8",
        )
        (root / ".github" / "dependabot.yml").write_text(
            'version: 2\nupdates:\n  - package-ecosystem: "github-actions"\n'
            '    directory: "/"\n    schedule:\n      interval: "weekly"\n',
            encoding="utf-8",
        )
        self.addCleanup(
            lambda: __import__("shutil").rmtree(root, ignore_errors=True)
        )
        return root

    def test_accepts_full_commit_pins(self) -> None:
        workflows, actions = MODULE.verify(
            self.fixture(revision="a" * 40)
        )
        self.assertEqual(workflows, 2)
        self.assertEqual(actions, 3)

    def test_rejects_mutable_action_tag(self) -> None:
        with self.assertRaises(MODULE.GitHubSecurityContractError):
            MODULE.verify(self.fixture(revision="v4"))


if __name__ == "__main__":
    unittest.main()
