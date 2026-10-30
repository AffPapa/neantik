import importlib.util
import json
import re
import sys
import tempfile
import unittest
from datetime import date, datetime, timezone
from unittest.mock import patch
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
    def test_manager_floor_matches_checked_release_baseline(self) -> None:
        root = SCRIPT.parents[1]
        baseline = json.loads((root / "runtime/security-baseline.json").read_text())
        swift = (root / "Sources/DirectUpdateCore/RuntimeSecurityBaseline.swift").read_text()
        match = re.search(r"minimumPublicChromiumVersion\s*=\s*\[([0-9,\s]+)\]", swift)
        self.assertIsNotNone(match)
        values = [int(part.strip()) for part in match.group(1).split(",")]
        self.assertEqual(".".join(map(str, values)), baseline["minimumPublicChromiumVersion"])

    def test_cli_default_day_uses_utc_not_host_calendar(self) -> None:
        # At this instant Bangkok is already October14, while UTC is October13.
        instant = datetime(2026, 10, 13, 21, 16, tzinfo=timezone.utc)
        with patch.object(MODULE, "datetime") as clock, patch.object(MODULE, "verify", return_value="verified") as verify, patch.object(sys, "argv", [str(SCRIPT)]), patch("builtins.print"):
            clock.now.return_value = instant
            MODULE.main()
        clock.now.assert_called_once_with(timezone.utc)
        self.assertEqual(verify.call_args.args[2], date(2026, 10, 13))

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

    def test_historical_provenance_never_exempts_current_public_release_gate(self) -> None:
        project = SCRIPT.parents[1]
        baseline_path = project / "runtime" / "security-baseline.json"
        baseline = json.loads(baseline_path.read_text(encoding="utf-8"))
        reviewed_day = date.fromisoformat(baseline["checkedAt"])
        for name in ("fingerprint-chromium-153.lock.json", "fingerprint-chromium-15498.lock.json"):
            for allow_alpha in (False, True):
                with self.subTest(lock=name, allow_alpha=allow_alpha), self.assertRaisesRegex(SystemExit, "is below the security baseline"):
                    MODULE.verify(project / "runtime" / name, baseline_path, reviewed_day,
                                  allow_public_alpha_tuples=allow_alpha)

    def test_stale_baseline_is_release_blocked(self) -> None:
        with self.assertRaisesRegex(SystemExit, "baseline is stale"):
            self.verify(
                "150.0.7871.187",
                self.baseline(checked_at="2026-07-17", published_at="2026-07-17"),
            )

    def test_zero_day_release_policy_requires_same_day_review(self) -> None:
        baseline = self.baseline(
            checked_at="2026-07-25",
            published_at="2026-07-23",
            maximum_age=0,
        )
        self.assertIn(
            "baseline age 0 day(s)",
            self.verify("150.0.7871.187", baseline, today=date(2026, 7, 25)),
        )
        with self.assertRaisesRegex(SystemExit, "baseline is stale"):
            self.verify("150.0.7871.187", baseline, today=date(2026, 7, 26))

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

    def test_source_only_candidate_lock_can_prepare_private_bundle_but_not_release(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            lock_path = self.write_json(
                root,
                "lock.json",
                {
                    "status": "source-qualified",
                    "fingerprintChromium": {"chromiumVersion": "150.0.7871.187"},
                },
            )
            baseline_path = self.write_json(root, "baseline.json", self.baseline())
            with self.assertRaisesRegex(SystemExit, "no verification object"):
                MODULE.verify(lock_path, baseline_path, date(2026, 7, 25))
            message = MODULE.verify(
                lock_path,
                baseline_path,
                date(2026, 7, 25),
                allow_unqualified_bundle=True,
            )
            self.assertIn("Pre-qualification bundle only", message)
            self.assertIn("still required before a public Direct release", message)

    def test_private_bundle_preparation_does_not_bypass_security_floor(self) -> None:
        with self.assertRaisesRegex(SystemExit, "below the security baseline"):
            self.verify("144.0.7559.132")


    def reviewed_branch_fixture(self):
        lock = self.lock("151.0.8000.2")
        lock["fingerprintChromium"]["commit"] = "1" * 40
        lock["sourceContractSHA256"] = "2" * 64
        baseline = self.baseline()
        issues = ["123456789", "123456790", "123456791", "123456792"]
        baseline["requiredSecurityFixes"] = issues
        baseline["reviewedSecurityBranches"] = {"151.0.8000": {
            "status": "verified", "minimumVersion": "151.0.8000.2",
            "sourceCommit": "1" * 40, "sourceContractSHA256": "2" * 64,
            "securityReference": baseline["reference"],
            "fixes": {issue: {"status": "included", "reference":
                "https://chromium.googlesource.com/chromium/src/+/" + "3" * 40}
                for issue in issues},
        }}
        return lock, baseline

    def verify_reviewed_fixture(self, lock, baseline, *, alpha=False):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            return MODULE.verify(self.write_json(root, "lock.json", lock),
                self.write_json(root, "baseline.json", baseline), date(2026, 7, 25),
                allow_public_alpha_tuples=alpha)

    def test_newer_milestone_or_other_branch_does_not_imply_fix_inclusion(self):
        for version in ("151.0.8000.2", "150.0.8000.2"):
            with self.subTest(version=version), self.assertRaisesRegex(SystemExit, "security branch"):
                self.verify(version)

    def test_source_only_alpha_cannot_skip_branch_review(self):
        lock, baseline = self.reviewed_branch_fixture()
        lock.pop("verification")
        lock["status"] = "source-qualified"
        baseline["reviewedSecurityBranches"] = {}
        with self.assertRaisesRegex(SystemExit, "security branch"):
            self.verify_reviewed_fixture(lock, baseline, alpha=True)

    def test_complete_source_bound_security_review_passes(self):
        lock, baseline = self.reviewed_branch_fixture()
        self.assertIn("source-bound security fix review", self.verify_reviewed_fixture(lock, baseline))
        fixes = baseline["reviewedSecurityBranches"]["151.0.8000"]["fixes"]
        fixes["123456789"]["reference"] = "https://chromium.googlesource.com/v8/v8.git/+/" + "3" * 40
        fixes["123456790"]["reference"] = "https://github.com/AffPapa/neantik/blob/" + "4" * 40 + "/docs/evidence/report.json"
        self.assertIn("verified", self.verify_reviewed_fixture(lock, baseline))

    def test_partial_or_unverified_fix_set_is_refused(self):
        for mutation in ("missing", "unknown", "wrong_count", "duplicate"):
            lock, baseline = self.reviewed_branch_fixture()
            review = baseline["reviewedSecurityBranches"]["151.0.8000"]
            if mutation == "missing": del review["fixes"]["123456789"]
            elif mutation == "unknown": review["fixes"]["123456789"]["status"] = "unknown"
            elif mutation == "wrong_count": baseline["securityFixCount"] = 5
            else: baseline["requiredSecurityFixes"][-1] = "123456789"
            with self.subTest(mutation=mutation), self.assertRaisesRegex(SystemExit, "security branch"):
                self.verify_reviewed_fixture(lock, baseline)

    def test_review_cannot_move_to_another_source_or_security_batch(self):
        for mutation in ("commit", "contract", "missing_contract", "batch", "pending"):
            lock, baseline = self.reviewed_branch_fixture()
            review = baseline["reviewedSecurityBranches"]["151.0.8000"]
            if mutation == "commit": lock["fingerprintChromium"]["commit"] = "4" * 40
            elif mutation == "contract": lock["sourceContractSHA256"] = "4" * 64
            elif mutation == "missing_contract": del lock["sourceContractSHA256"]
            elif mutation == "batch": baseline["reference"] += "-new-batch"
            else: review["status"] = "pending"
            with self.subTest(mutation=mutation), self.assertRaisesRegex(SystemExit, "security branch"):
                self.verify_reviewed_fixture(lock, baseline)

    def test_reviewed_floor_must_match_branch_and_runtime(self):
        for floor in ("151.0.8000.3", "151.0.8100.1"):
            lock, baseline = self.reviewed_branch_fixture()
            baseline["reviewedSecurityBranches"]["151.0.8000"]["minimumVersion"] = floor
            with self.subTest(floor=floor), self.assertRaisesRegex(SystemExit, "reviewed branch floor"):
                self.verify_reviewed_fixture(lock, baseline)

    def test_security_evidence_is_primary_or_pinned_and_not_applicable_is_explained(self):
        for reference in ("https://example.com/unverified", "https://github.com/AffPapa/neantik/blob/main/report.json", "https://chromium.googlesource.com:wrong/commit", "https://chromium.googlesource.com/", "https://chromium.googlesource.com/chromium/src/+/refs/heads/main/file.cc", "https://chromereleases.googleblog.com/2026/10/post.html",
                          "https://chromium.googlesource.com/chromium/src/+/" + "3" * 40 + "/../../main/file.cc",
                          "https://chromium.googlesource.com/chromium/src/+/" + "3" * 40 + "/%2e%2e/main"):
            lock, baseline = self.reviewed_branch_fixture()
            baseline["reviewedSecurityBranches"]["151.0.8000"]["fixes"]["123456789"]["reference"] = reference
            with self.subTest(reference=reference), self.assertRaisesRegex(SystemExit, "security evidence"):
                self.verify_reviewed_fixture(lock, baseline)
        lock, baseline = self.reviewed_branch_fixture()
        proof = baseline["reviewedSecurityBranches"]["151.0.8000"]["fixes"]["123456789"]
        proof["status"] = "not-applicable"
        with self.assertRaisesRegex(SystemExit, "specific reason"):
            self.verify_reviewed_fixture(lock, baseline)
        for reason in (None, 0, {}, "", "  "):
            proof["reason"] = reason
            with self.subTest(reason=reason), self.assertRaisesRegex(SystemExit, "specific reason"):
                self.verify_reviewed_fixture(lock, baseline)
        proof["reason"] = "Synthetic fixture: source operation absent from this platform"
        self.assertIn("verified", self.verify_reviewed_fixture(lock, baseline))

    def test_delivered_runtime_below_current_floor_cannot_use_alpha(self):
        project = SCRIPT.parents[1]
        baseline_path = project / "runtime/security-baseline.json"
        baseline = json.loads(baseline_path.read_text())
        for alpha in (False, True):
            with self.subTest(alpha=alpha), self.assertRaisesRegex(SystemExit, "below the security baseline"):
                MODULE.verify(project / "runtime/fingerprint-chromium-15612-font-system-v1.lock.json",
                    baseline_path, date.fromisoformat(baseline["checkedAt"]),
                    allow_public_alpha_tuples=alpha)



if __name__ == "__main__":
    unittest.main()
