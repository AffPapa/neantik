#!/usr/bin/env python3
"""Regression tests for the restricted AffPapa release snapshot contract."""

from __future__ import annotations

import hashlib
import json
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
VALIDATOR = ROOT / "ops/affpapa/server/neantik-validate-release"
VERSION = "0.3.15"
DMG = f"NeAntik-{VERSION}-arm64-notarized.dmg"
ZIP = f"NeAntik-{VERSION}-arm64-notarized.zip"


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


class ReleaseValidatorTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(
            prefix="neantik-affpapa-validator-"
        )
        self.snapshot = Path(self.temporary.name)
        self.dmg_bytes = b"dmg\n"
        self.zip_bytes = b"zip\n"
        self.release = {
            "schemaVersion": 1,
            "product": "NeAntik",
            "version": VERSION,
            "build": 18,
            "releaseDate": "2026-08-04",
            "status": "public-alpha",
            "distribution": "direct",
            "platform": {
                "operatingSystem": "macOS 14 or later",
                "architecture": "arm64",
                "hardware": "Apple Silicon",
            },
            "runtime": {
                "name": "Chromium",
                "version": "150.0.7871.186",
                "gpu": "Metal",
            },
            "source": {
                "repository": "https://github.com/AffPapa/neantik",
                "tag": f"v{VERSION}",
                "commit": "73b74f8b8ba7e66cc3ea2b5b88dcd52c7b3dc5f8",
                "release": (
                    "https://github.com/AffPapa/neantik/releases/tag/"
                    f"v{VERSION}"
                ),
            },
            "artifacts": [
                {
                    "format": "dmg",
                    "filename": DMG,
                    "url": f"https://affpapa.org/neantik/downloads/{DMG}",
                    "sizeBytes": len(self.dmg_bytes),
                    "sha256": digest(self.dmg_bytes),
                    "developerIdSigned": True,
                    "notarized": True,
                    "stapled": True,
                    "gatekeeper": "accepted",
                },
                {
                    "format": "zip",
                    "filename": ZIP,
                    "url": f"https://affpapa.org/neantik/downloads/{ZIP}",
                    "sizeBytes": len(self.zip_bytes),
                    "sha256": digest(self.zip_bytes),
                    "developerIdSigned": True,
                    "notarized": True,
                    "stapled": True,
                    "gatekeeper": "accepted",
                },
            ],
            "privacy": {
                "telemetry": "disabled",
                "profileData": "local-only",
                "proxyPasswords": "macOS Keychain",
            },
            "securityBaseline": {
                "runtimeVersion": "150.0.7871.186",
                "source": "Chrome Releases",
                "releaseChannel": "public-alpha",
            },
            "limitations": ["Public-alpha regression fixture."],
        }
        self.content = {
            "schemaVersion": 1,
            "product": "NeAntik",
            "releaseVersion": VERSION,
            "updatedAt": "2026-08-04",
            "changelog": [
                {
                    "version": VERSION,
                    "build": 18,
                    "date": "4 августа 2026",
                    "label": "Public Alpha",
                    "items": ["Проверка канонического release gate"],
                }
            ],
        }
        self.write_snapshot()

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def write_snapshot(self) -> None:
        (self.snapshot / DMG).write_bytes(self.dmg_bytes)
        (self.snapshot / ZIP).write_bytes(self.zip_bytes)
        for filename, data in (
            (DMG, self.dmg_bytes),
            (ZIP, self.zip_bytes),
        ):
            (self.snapshot / f"{filename}.sha256").write_text(
                f"{digest(data)}  {filename}\n",
                encoding="utf-8",
            )
        (self.snapshot / "release.json").write_text(
            json.dumps(self.release, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        (self.snapshot / "content.json").write_text(
            json.dumps(self.content, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )

    def validate(self) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(VALIDATOR), str(self.snapshot)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def assert_rejected(self, expected: str) -> None:
        result = self.validate()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(expected, result.stderr)

    def test_accepts_exact_canonical_snapshot(self) -> None:
        result = self.validate()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "VALIDATION OK")

    def test_rejects_missing_artifact(self) -> None:
        (self.snapshot / ZIP).unlink()
        self.assert_rejected("snapshot missing required files")

    def test_rejects_missing_sidecar(self) -> None:
        (self.snapshot / f"{ZIP}.sha256").unlink()
        self.assert_rejected("snapshot missing required files")

    def test_rejects_corrupt_artifact(self) -> None:
        (self.snapshot / ZIP).write_bytes(b"changed")
        self.assert_rejected("actual size")

    def test_rejects_wrong_sha(self) -> None:
        self.release["artifacts"][1]["sha256"] = "0" * 64
        self.write_snapshot()
        self.assert_rejected("release.json")

    def test_rejects_wrong_repository(self) -> None:
        self.release["source"]["repository"] = (
            "https://github.com/example/neantik"
        )
        self.write_snapshot()
        self.assert_rejected("source.repository")

    def test_rejects_content_version_mismatch(self) -> None:
        self.content["releaseVersion"] = "0.3.99"
        self.write_snapshot()
        self.assert_rejected("content.releaseVersion")

    def set_changelog_items(self, items: list[str]) -> None:
        self.content["changelog"][0]["items"] = items
        self.write_snapshot()

    def test_accepts_ordinary_russian_verb_in_changelog(self) -> None:
        """A normal sentence is not a placeholder marker.

        The published 0.3.20 changelog describes the bulk import flow as
        «вставить список прокси». Substring matching on the bare verb
        «вставить» rejected that correct release copy.
        """
        self.set_changelog_items(
            [
                "Массовое создание профилей сведено к локальному сценарию "
                "«вставить список прокси → проверить предпросмотр → "
                "создать» без скрытых сетевых запросов.",
            ]
        )
        result = self.validate()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "VALIDATION OK")

    def test_accepts_ordinary_english_verb_in_changelog(self) -> None:
        self.set_changelog_items(
            ["Insert the profile into the workspace and continue."]
        )
        result = self.validate()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "VALIDATION OK")

    def test_rejects_todo_marker(self) -> None:
        self.set_changelog_items(["TODO: заполнить описание релиза"])
        self.assert_rejected("placeholder marker: todo")

    def test_rejects_fixme_marker(self) -> None:
        self.set_changelog_items(["FIXME проверить ссылку на загрузку"])
        self.assert_rejected("placeholder marker: fixme")

    def test_rejects_change_me_marker(self) -> None:
        self.set_changelog_items(["Версия CHANGE_ME готова к выпуску"])
        self.assert_rejected("placeholder marker: changeme")

    def test_rejects_placeholder_marker(self) -> None:
        self.set_changelog_items(["placeholder text for the release notes"])
        self.assert_rejected("placeholder marker: placeholder")

    def test_rejects_unfinished_russian_template(self) -> None:
        self.set_changelog_items(["вставить сюда список изменений"])
        self.assert_rejected("placeholder marker: вставить-сюда")

    def test_rejects_unfinished_english_template(self) -> None:
        self.set_changelog_items(["insert release version here"])
        self.assert_rejected("placeholder marker: insert-here")

    def test_rejects_marker_in_release_json(self) -> None:
        self.release["securityBaseline"]["source"] = "TODO"
        self.write_snapshot()
        self.assert_rejected("release.json contains placeholder marker: todo")


if __name__ == "__main__":
    unittest.main()
