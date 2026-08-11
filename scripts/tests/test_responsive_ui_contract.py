import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
CONTENT = ROOT / "Sources" / "NeAntik" / "ContentView.swift"
EDITOR = ROOT / "Sources" / "NeAntik" / "ProfileEditorView.swift"
AUDIT = ROOT / "Sources" / "NeAntik" / "FingerprintAuditView.swift"


class ResponsiveUIContractTests(unittest.TestCase):
    def test_workspace_owns_its_two_columns_without_titlebar_overlap(
        self,
    ) -> None:
        text = CONTENT.read_text(encoding="utf-8")
        self.assertNotIn(".safeAreaInset(edge: .top", text)
        self.assertNotIn(".padding(.top, 46)", text)
        self.assertNotIn("windowTitlebarInset", text)
        self.assertNotIn("NavigationSplitView", text)
        self.assertNotIn(".searchable(", text)
        self.assertNotIn("ToolbarItem(", text)
        self.assertIn("GeometryReader", text)
        self.assertIn("HStack(spacing: 0)", text)
        self.assertIn("WorkspaceLayout.sidebarWidth", text)
        self.assertIn("isSidebarVisible", text)

    def test_primary_profile_actions_are_pinned_above_scrollable_details(
        self,
    ) -> None:
        text = CONTENT.read_text(encoding="utf-8")
        root = text.index("struct ProfileDetailView")
        body = text.index("var body: some View", root)
        header = text.index("pinnedHeader", body)
        scroll = text.index("ScrollView", body)
        actions = text.index("primaryActions", header)
        self.assertLess(header, actions)
        self.assertLess(header, scroll)
        for action in (
            '"Запустить"',
            '"Изменить"',
            '"Ещё"',
            '"Показать данные"',
            '"Удалить профиль"',
        ):
            self.assertIn(action, text)
        self.assertNotIn(
            'compactActionLabel(\n                    "Проверить профиль"',
            text,
        )

    def test_proxy_import_is_local_and_connection_test_is_optional(
        self,
    ) -> None:
        text = EDITOR.read_text(encoding="utf-8")
        self.assertIn('Label("Вставить прокси"', text)
        self.assertIn('Label("Проверить прокси"', text)
        self.assertIn("private func importProxy()", text)
        self.assertNotIn("importProxyAndTest", text)
        import_start = text.index("private func importProxy()")
        test_start = text.index("private func startProxyTest(")
        import_body = text[import_start:test_start]
        self.assertNotIn("startProxyTest(", import_body)

    def test_advanced_editor_row_has_explicit_button(self) -> None:
        text = EDITOR.read_text(encoding="utf-8")
        self.assertIn("showsAdvancedOptions.toggle()", text)
        self.assertNotIn(
            'DisclosureGroup(\n            "Дополнительно"',
            text,
        )
        self.assertNotIn(".onSubmit(save)", text)

    def test_narrow_proxy_and_audit_controls_have_fallbacks(self) -> None:
        editor = EDITOR.read_text(encoding="utf-8")
        audit = AUDIT.read_text(encoding="utf-8")
        self.assertGreaterEqual(editor.count("ViewThatFits"), 2)
        self.assertGreaterEqual(audit.count("ViewThatFits"), 2)
        self.assertIn(".focused($primaryActionIsFocused)", audit)


if __name__ == "__main__":
    unittest.main()
