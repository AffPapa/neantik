from __future__ import annotations

import importlib.util
import argparse
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "scripts/prepare-affpapa-release-snapshot.py"
SPEC = importlib.util.spec_from_file_location("prepare_affpapa_snapshot", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class PrepareReleaseSnapshotTests(unittest.TestCase):
    def test_reads_multiline_notes_for_exact_candidate(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            changelog = Path(temporary) / "CHANGELOG.md"
            changelog.write_text(
                "# Changes\n\n"
                "## Direct 0.3.17 (20) — в разработке\n\n"
                "- Первая строка\n"
                "  продолжается здесь.\n\n"
                "- Второй пункт.\n\n"
                "## Direct 0.3.16 (19) — old\n\n- Старое.\n",
                encoding="utf-8",
            )
            self.assertEqual(
                MODULE.read_release_notes(changelog, "0.3.17", 20),
                ["Первая строка продолжается здесь.", "Второй пункт."],
            )

    def test_rejects_wrong_artifact_name(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            artifact = Path(temporary) / "wrong.dmg"
            artifact.write_bytes(b"dmg")
            with self.assertRaisesRegex(MODULE.SnapshotError, "Expected"):
                MODULE.artifact_entry(artifact, "0.3.17", "dmg")

    def test_builds_six_file_snapshot_with_one_release_date(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "project"
            output = Path(temporary) / "release"
            (root / "Resources").mkdir(parents=True)
            (root / "runtime").mkdir()
            (root / "ops/affpapa/bootstrap").mkdir(parents=True)
            (root / "ops/affpapa/server").mkdir(parents=True)
            with (root / "Resources/Info.plist").open("wb") as target:
                plistlib.dump(
                    {
                        "CFBundleShortVersionString": "0.3.17",
                        "CFBundleVersion": "20",
                    },
                    target,
                )
            (root / "runtime/fingerprint-chromium.lock.json").write_text(
                json.dumps(
                    {
                        "fingerprintChromium": {
                            "chromiumVersion": "151.0.7922.108"
                        }
                    }
                ),
                encoding="utf-8",
            )
            (root / "CHANGELOG.md").write_text(
                "## Direct 0.3.17 (20) — ready\n\n- Готовый выпуск.\n",
                encoding="utf-8",
            )
            (root / "ops/affpapa/bootstrap/content.json").write_text(
                json.dumps(
                    {
                        "schemaVersion": 1,
                        "product": "NeAntik",
                        "releaseVersion": "0.3.16",
                        "updatedAt": "2026-08-06",
                        "changelog": [
                            {
                                "version": "0.3.16",
                                "build": 19,
                                "date": "6 августа 2026",
                                "items": ["Старый выпуск."],
                            }
                        ],
                    }
                ),
                encoding="utf-8",
            )
            validator = root / "ops/affpapa/server/neantik-validate-release"
            validator.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            validator.chmod(0o755)
            dmg = Path(temporary) / "NeAntik-0.3.17-arm64-notarized.dmg"
            zip_file = Path(temporary) / "NeAntik-0.3.17-arm64-notarized.zip"
            dmg.write_bytes(b"dmg")
            zip_file.write_bytes(b"zip")
            args = argparse.Namespace(
                project_root=root,
                output=output,
                release_date="2026-08-12",
                dmg=dmg,
                zip=zip_file,
            )
            with patch.object(MODULE, "git_commit", return_value="a" * 40):
                MODULE.build_snapshot(args)
            self.assertEqual(
                {path.name for path in output.iterdir()},
                {
                    "release.json",
                    "content.json",
                    dmg.name,
                    f"{dmg.name}.sha256",
                    zip_file.name,
                    f"{zip_file.name}.sha256",
                },
            )
            release = json.loads((output / "release.json").read_text())
            content = json.loads((output / "content.json").read_text())
            self.assertEqual(release["releaseDate"], "2026-08-12")
            self.assertEqual(content["updatedAt"], "2026-08-12")
            self.assertEqual(
                content["changelog"][0]["date"], "12 августа 2026"
            )


if __name__ == "__main__":
    unittest.main()
