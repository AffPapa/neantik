from __future__ import annotations

import importlib.util
import argparse
import json
from pathlib import Path
import plistlib
import subprocess
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


RELEASE_COMMIT = "a" * 40
TOOLING_COMMIT = "b" * 40
RELEASE_TAG = "v0.3.17"
PINNED_ITEM = (
    "Массовое создание профилей сведено к локальному сценарию "
    "«вставить список прокси → проверить предпросмотр → создать»."
)


def release_source_tree() -> dict[str, bytes]:
    """Files as they exist in the immutable release commit."""
    return {
        "Resources/Info.plist": plistlib.dumps(
            {"CFBundleShortVersionString": "0.3.17", "CFBundleVersion": "20"}
        ),
        "runtime/fingerprint-chromium.lock.json": json.dumps(
            {"fingerprintChromium": {"chromiumVersion": "152.0.7977.64"}}
        ).encode("utf-8"),
        "CHANGELOG.md": (
            "## Direct 0.3.17 (20) — ready\n\n" f"- {PINNED_ITEM}\n"
        ).encode("utf-8"),
        "ops/affpapa/bootstrap/content.json": json.dumps(
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
        ).encode("utf-8"),
    }


def newer_tooling_worktree(root: Path) -> None:
    """Worktree state that is deliberately newer than the release commit."""
    (root / "Resources").mkdir(parents=True)
    (root / "runtime").mkdir()
    (root / "ops/affpapa/bootstrap").mkdir(parents=True)
    (root / "ops/affpapa/server").mkdir(parents=True)
    with (root / "Resources/Info.plist").open("wb") as target:
        plistlib.dump(
            {"CFBundleShortVersionString": "0.3.18", "CFBundleVersion": "21"},
            target,
        )
    (root / "runtime/fingerprint-chromium.lock.json").write_text(
        json.dumps({"fingerprintChromium": {"chromiumVersion": "151.0.0.1"}}),
        encoding="utf-8",
    )
    (root / "CHANGELOG.md").write_text(
        "## Direct 0.3.18 (21) — tooling only\n\n- Не должно попасть в релиз.\n",
        encoding="utf-8",
    )
    (root / "ops/affpapa/bootstrap/content.json").write_text(
        json.dumps(
            {
                "schemaVersion": 1,
                "product": "NeAntik",
                "releaseVersion": "0.3.18",
                "updatedAt": "2026-08-29",
                "changelog": [
                    {
                        "version": "0.3.18",
                        "build": 21,
                        "date": "29 августа 2026",
                        "items": ["Не должно попасть в релиз."],
                    }
                ],
            }
        ),
        encoding="utf-8",
    )
    validator = root / "ops/affpapa/server/neantik-validate-release"
    validator.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    validator.chmod(0o755)


class ReleaseSourceSeparationTests(unittest.TestCase):
    """The release source, not the release tooling, defines what is published."""

    def test_pinned_release_source_beats_newer_tooling_commit(self) -> None:
        source = release_source_tree()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "project"
            output = Path(temporary) / "release"
            newer_tooling_worktree(root)
            dmg = Path(temporary) / "NeAntik-0.3.17-arm64-notarized.dmg"
            zip_file = Path(temporary) / "NeAntik-0.3.17-arm64-notarized.zip"
            dmg.write_bytes(b"dmg")
            zip_file.write_bytes(b"zip")
            args = argparse.Namespace(
                project_root=root,
                output=output,
                release_date="2026-08-30",
                dmg=dmg,
                zip=zip_file,
                release_tag=RELEASE_TAG,
                release_commit=RELEASE_COMMIT,
            )
            with (
                patch.object(
                    MODULE, "git_commit", return_value=TOOLING_COMMIT
                ),
                patch.object(MODULE, "verify_release_source") as verified,
                patch.object(
                    MODULE,
                    "read_source_bytes",
                    side_effect=lambda _root, commit, relative: source[
                        relative
                    ],
                ),
            ):
                result = MODULE.build_snapshot(args)
            verified.assert_called_once()
            self.assertEqual(
                verified.call_args.args[1:3], (RELEASE_TAG, RELEASE_COMMIT)
            )
            release = json.loads((output / "release.json").read_text())
            content = json.loads((output / "content.json").read_text())
            self.assertEqual(release["source"]["commit"], RELEASE_COMMIT)
            self.assertNotEqual(release["source"]["commit"], TOOLING_COMMIT)
            self.assertEqual(release["source"]["tag"], RELEASE_TAG)
            self.assertEqual(release["version"], "0.3.17")
            self.assertEqual(release["build"], 20)
            self.assertEqual(release["runtime"]["version"], "152.0.7977.64")
            self.assertEqual(content["changelog"][0]["items"], [PINNED_ITEM])
            self.assertEqual(result["releaseCommit"], RELEASE_COMMIT)
            self.assertEqual(result["toolingCommit"], TOOLING_COMMIT)
            self.assertEqual(result["releaseSourcePinned"], "yes")

    def test_release_tag_and_commit_must_be_paired(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            args = argparse.Namespace(
                project_root=Path(temporary) / "project",
                output=Path(temporary) / "release",
                release_date="2026-08-30",
                dmg=Path(temporary) / "a.dmg",
                zip=Path(temporary) / "a.zip",
                release_tag=RELEASE_TAG,
                release_commit=None,
            )
            with self.assertRaisesRegex(MODULE.SnapshotError, "must be used together"):
                MODULE.build_snapshot(args)

    def test_rejects_tag_version_mismatch(self) -> None:
        source = release_source_tree()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "project"
            newer_tooling_worktree(root)
            dmg = Path(temporary) / "NeAntik-0.3.17-arm64-notarized.dmg"
            zip_file = Path(temporary) / "NeAntik-0.3.17-arm64-notarized.zip"
            dmg.write_bytes(b"dmg")
            zip_file.write_bytes(b"zip")
            args = argparse.Namespace(
                project_root=root,
                output=Path(temporary) / "release",
                release_date="2026-08-30",
                dmg=dmg,
                zip=zip_file,
                release_tag="v0.3.99",
                release_commit=RELEASE_COMMIT,
            )
            with (
                patch.object(MODULE, "git_commit", return_value=TOOLING_COMMIT),
                patch.object(MODULE, "verify_release_source"),
                patch.object(
                    MODULE,
                    "read_source_bytes",
                    side_effect=lambda _root, commit, relative: source[relative],
                ),
                self.assertRaisesRegex(MODULE.SnapshotError, "does not match"),
            ):
                MODULE.build_snapshot(args)


class VerifyReleaseSourceTests(unittest.TestCase):
    """The pinned pair is bound to the immutable GitHub release."""

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.dmg = self.root / "NeAntik-0.3.20-arm64-notarized.dmg"
        self.zip = self.root / "NeAntik-0.3.20-arm64-notarized.zip"
        self.dmg.write_bytes(b"dmg")
        self.zip.write_bytes(b"zip")
        self.commit = "b" * 39 + "c"
        self.tag = "v0.3.20"
        self.release = {
            "tagName": self.tag,
            "isDraft": False,
            "isImmutable": True,
        }
        self.calls: list[list[str]] = []

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def fake_gh(self, arguments: list[str]) -> str:
        self.calls.append(arguments)
        if arguments[0] == "api":
            return self.commit + "\n"
        if arguments[:2] == ["release", "view"]:
            return json.dumps(self.release)
        if arguments[:2] == ["release", "verify-asset"]:
            return "Verification succeeded!\n"
        raise AssertionError(f"unexpected gh call: {arguments}")

    def run_verify(self, tag: str | None = None, commit: str | None = None):
        with (
            patch.object(
                MODULE.subprocess,
                "run",
                return_value=subprocess.CompletedProcess([], 0),
            ),
            patch.object(MODULE, "gh_output", side_effect=self.fake_gh),
        ):
            return MODULE.verify_release_source(
                self.root,
                tag or self.tag,
                commit or self.commit,
                (self.dmg, self.zip),
            )

    def test_accepts_immutable_release_and_verifies_both_assets(self) -> None:
        self.run_verify()
        verified = [
            call[2] for call in self.calls if call[:2] == ["release", "verify-asset"]
        ]
        self.assertEqual(verified, [self.tag, self.tag])
        assets = [
            call[3] for call in self.calls if call[:2] == ["release", "verify-asset"]
        ]
        self.assertEqual(assets, [str(self.dmg), str(self.zip)])

    def test_rejects_tag_pointing_at_another_commit(self) -> None:
        self.commit = "d" * 40
        with self.assertRaisesRegex(MODULE.SnapshotError, "resolves to"):
            self.run_verify(commit="e" * 40)

    def test_rejects_draft_release(self) -> None:
        self.release["isDraft"] = True
        with self.assertRaisesRegex(MODULE.SnapshotError, "is a draft"):
            self.run_verify()

    def test_rejects_mutable_release(self) -> None:
        self.release["isImmutable"] = False
        with self.assertRaisesRegex(MODULE.SnapshotError, "not immutable"):
            self.run_verify()

    def test_rejects_non_canonical_tag(self) -> None:
        with self.assertRaisesRegex(MODULE.SnapshotError, "must be vSEMVER"):
            self.run_verify(tag="latest")

    def test_rejects_non_canonical_commit(self) -> None:
        with self.assertRaisesRegex(MODULE.SnapshotError, "40 lowercase"):
            self.run_verify(commit="BB0D288")


if __name__ == "__main__":
    unittest.main()
