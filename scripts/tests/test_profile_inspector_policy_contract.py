import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]


class ProfileInspectorPolicyContractTests(unittest.TestCase):
    def test_toolbar_and_command_use_the_shared_policy(self):
        content = (ROOT / "Sources/NeAntik/ContentView.swift").read_text()
        toolbar = (ROOT / "Sources/NeAntik/WorkspaceToolbarContent.swift").read_text()
        self.assertIn("canToggleInspector: ProfileInspectorPolicy.canToggle(", content)
        self.assertIn(".disabled(!ProfileInspectorPolicy.canToggle(", toolbar)
        self.assertIn("guard !isWorkspaceModalPresented else { return .unavailable }", content)

    def test_action_rechecks_policy_and_modal_guard(self):
        content = (ROOT / "Sources/NeAntik/ContentView.swift").read_text()
        action = content.split("private func toggleProfileInspector()", 1)[1].split(
            "private func applyWorkspaceQuery", 1
        )[0]
        self.assertIn("guard !isWorkspaceModalPresented,", action)
        self.assertIn("ProfileInspectorPolicy.canToggle(", action)
        self.assertIn("showsProfileInspector.toggle()", action)


if __name__ == "__main__":
    unittest.main()
