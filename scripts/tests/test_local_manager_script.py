import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "run-local-manager.sh"
WRAPPER = ROOT / "Develop-NeAntik.command"
OPEN_SOURCE_VERIFIER = ROOT / "scripts" / "verify-open-source-tree.py"


class LocalManagerScriptTests(unittest.TestCase):
    def test_fast_path_is_isolated_from_release(self) -> None:
        text = SCRIPT.read_text(encoding="utf-8")
        self.assertIn("app.neantik.desktop.dev", text)
        self.assertIn("NeAntik Development", text)
        self.assertIn("app.neantik.dev.proxy", text)
        self.assertIn("--scratch-path", text)
        self.assertIn("--disable-sandbox", text)
        self.assertIn("/bin/cp -cR", text)
        self.assertIn('cd "$PROJECT_DIR"', text)
        self.assertIn(
            'exec "$DEVELOPMENT_APP/Contents/MacOS/NeAntik"',
            text,
        )
        self.assertNotIn("/usr/bin/open -n", text)

        for forbidden in (
            "notarytool",
            "stapler",
            "Release-NeAntik.command",
            "direct-candidate-manifest",
            "fingerprint-audit",
            "neantik-affpapa-release",
            "github",
        ):
            self.assertNotIn(forbidden, text)

    def test_fast_path_never_rewrites_dist(self) -> None:
        text = SCRIPT.read_text(encoding="utf-8")
        self.assertNotIn('>"$SOURCE_APP', text)
        self.assertNotIn("dist/NeAntik-Integrated.app", text)
        self.assertIn(
            'DEVELOPMENT_ROOT="$PROJECT_DIR/.build/neantik-local"',
            text,
        )
        self.assertIn(
            'DEVELOPMENT_APP="$DEVELOPMENT_ROOT/NeAntik-Dev.app"',
            text,
        )

    def test_root_wrapper_only_dispatches_to_local_manager(self) -> None:
        text = WRAPPER.read_text(encoding="utf-8")
        self.assertIn("scripts/run-local-manager.sh", text)
        self.assertNotIn("Release-NeAntik", text)

    def test_open_source_gate_ignores_only_gitignored_build_outputs(
        self,
    ) -> None:
        text = OPEN_SOURCE_VERIFIER.read_text(encoding="utf-8")
        self.assertIn('"--cached"', text)
        self.assertIn('"--others"', text)
        self.assertIn('"--exclude-standard"', text)
        self.assertIn(
            "Exported source archives may not contain .git",
            text,
        )


if __name__ == "__main__":
    unittest.main()
