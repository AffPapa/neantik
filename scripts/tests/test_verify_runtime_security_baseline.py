import importlib.util
import json
import tempfile
import unittest
from datetime import date
from pathlib import Path


SCRIPT = (
    Path(__file__).resolve().parents[1]
    / "verify-runtime-security-baseline.py"
)
SPEC = importlib.util.spec_from_file_location("runtime_security_baseline", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class RuntimeSecurityBaselineTests(unittest.TestCase):
    def write_json(self, root: Path, name: str, value: object) -> Path:
        path = root / name
        path.write_text(json.dumps(value), encoding="utf-8")
        return path

    def lock(
        self,
        version: str,
        tuple_status: str = "verified",
    ) -> dict[str, object]:
        return {
            "fingerprintChromium": {"chromiumVersion": version},
            "verification": {"coherentAppleDeviceTuples": tuple_status},
        }

    def baseline(
        self,
        minimum: str = "150.0.7871.186",
        checked_at: str = "2026-07-25",
        published_at: str = "2026-07-23",
        maximum_age: int = 7,
    ) -> dict[str, object]:
        return {
            "schemaVersion": 1,
            "checkedAt": checked_at,
            "publishedAt": published_at,
            "maximumAgeDays": maximum_age,
            "minimumPublicChromiumVersion": minimum,
            "alsoObservedPublicChromiumVersions": ["150.0.7871.187"],
            "channel": "Desktop Stable",
            "platforms": ["macOS"],
            "securityFixCount": 4,
            "reference": "https://chromereleases.googleblog.com/2026/07/stable-channel-update-for-desktop_01320465736.html",
            "referenceTitle": "Stable Channel Update for Desktop",
            "sourceLabel": "Chrome Releases",
            "releaseBoundary": "This is a manually pinned primary-source security baseline. It is not a live updater. Refresh checkedAt, versions, securityFixCount and reference before every public Direct release.",
        }

    def verify(
        self,
        runtime: str,
        baseline: dict[str, object] | None = None,
        today: date = date(2026, 7, 25),
    ) -> str:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            lock_path = self.write_json(root, "lock.json", self.lock(runtime))
            baseline_path = self.write_json(
                root, "baseline.json", baseline or self.baseline()
            )
            return MODULE.verify(lock_path, baseline_path, today)

    def test_current_or_newer_runtime_passes(self) -> None:
        message = self.verify("150.0.7871.187")
        self.assertIn("verified", message)

    def test_zero_fix_count_is_valid_when_official_post_enumerates_none(self) -> None:
        baseline = self.baseline()
        baseline["securityFixCount"] = 0
        message = self.verify("150.0.7871.187", baseline)
        self.assertIn("security fixes not enumerated", message)

    def test_old_runtime_is_release_blocked(self) -> None:
        with self.assertRaisesRegex(SystemExit, "Public Direct release blocked"):
            self.verify("144.0.7559.132")

    def test_stale_baseline_is_release_blocked(self) -> None:
        with self.assertRaisesRegex(SystemExit, "baseline is stale"):
            self.verify(
                "150.0.7871.187",
                self.baseline(checked_at="2026-07-17", published_at="2026-07-17"),
            )

    def test_future_baseline_is_rejected(self) -> None:
        with self.assertRaisesRegex(SystemExit, "in the future"):
            self.verify(
                "150.0.7871.187",
                self.baseline(checked_at="2026-07-26"),
            )

    def test_invalid_version_is_rejected(self) -> None:
        with self.assertRaisesRegex(SystemExit, "four-part numeric"):
            self.verify("150.0.beta.1")

    def test_unverified_device_tuples_block_current_runtime(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            lock_path = self.write_json(
                root,
                "lock.json",
                self.lock("150.0.7871.187", "pending-security-rebase"),
            )
            baseline_path = self.write_json(
                root,
                "baseline.json",
                self.baseline(),
            )
            with self.assertRaisesRegex(
                SystemExit,
                "coherent Apple device tuples are not verified",
            ):
                MODULE.verify(lock_path, baseline_path, date(2026, 7, 25))

    def test_missing_provenance_fails_closed(self) -> None:
        broken = self.baseline()
        del broken["securityFixCount"]
        with self.assertRaisesRegex(SystemExit, "securityFixCount"):
            self.verify("150.0.7871.187", broken)

    def test_future_publication_date_is_rejected(self) -> None:
        broken = self.baseline()
        broken["publishedAt"] = "2026-07-26"
        with self.assertRaisesRegex(SystemExit, "publishedAt"):
            self.verify("150.0.7871.187", broken, today=date(2026, 7, 26))

    def test_missing_device_tuple_status_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            lock_path = self.write_json(
                root,
                "lock.json",
                {"fingerprintChromium": {"chromiumVersion": "150.0.7871.187"}},
            )
            baseline_path = self.write_json(
                root,
                "baseline.json",
                self.baseline(),
            )
            with self.assertRaisesRegex(
                SystemExit,
                "no verification object",
            ):
                MODULE.verify(lock_path, baseline_path, date(2026, 7, 25))

    def test_source_only_candidate_lock_is_allowed_for_public_alpha_only(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            lock_path = self.write_json(
                root,
                "lock.json",
                {
                    "status": "source-qualified",
                    "fingerprintChromium": {
                        "chromiumVersion": "150.0.7871.187"
                    },
                },
            )
            baseline_path = self.write_json(
                root,
                "baseline.json",
                self.baseline(),
            )
            with self.assertRaisesRegex(
                SystemExit,
                "no verification object",
            ):
                MODULE.verify(lock_path, baseline_path, date(2026, 7, 25))
            message = MODULE.verify(
                lock_path,
                baseline_path,
                date(2026, 7, 25),
                allow_public_alpha_tuples=True,
            )
            self.assertIn("source-only runtime lock", message)


if __name__ == "__main__":
    unittest.main()
