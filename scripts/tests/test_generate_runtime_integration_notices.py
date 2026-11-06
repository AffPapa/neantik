import importlib.util
import hashlib
import json
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch
from pathlib import Path

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "generate-runtime-integration-notices.py"
SPEC = importlib.util.spec_from_file_location(
    "generate_runtime_integration_notices",
    SCRIPT,
)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class RuntimeIntegrationNoticesTests(unittest.TestCase):
    def write_m157_candidate_fixture(self, root):
        import chromium_157_release_evidence as m157

        source = {
            "sourceHead": m157.PORT_HEAD,
            "sourcePatchSHA256": m157.PORT_PATCH_SHA256,
            "buildArgsSHA256": m157.ARGS_SHA256,
            "buildOutputDirectory": "out/neantik157-port-smoke-correctargs3",
        }
        with patch.object(m157, "verify_source_root", return_value=source):
            provenance = m157.build_provenance(root / "synthetic-source", ROOT)
        provenance_path = root / "source-provenance.json"
        provenance_path.write_text(json.dumps(provenance, indent=2, sort_keys=True) + "\n")
        lock = m157.expected_lock(provenance_path, ROOT)
        lock_path = root / "candidate-lock.json"
        lock_path.write_text(json.dumps(lock, indent=2, sort_keys=True) + "\n")
        return m157, provenance_path, lock_path

    def test_m157_candidate_renders_source_bound_notices_without_release_claim(self):
        with tempfile.TemporaryDirectory() as temporary:
            _, provenance, lock = self.write_m157_candidate_fixture(Path(temporary))
            rendered = MODULE.render_m154_notices(
                project_root=ROOT,
                runtime_lock=lock,
                source_provenance=provenance,
            )
            self.assertIn("Chromium: `157.0.8103.39`", rendered)
            self.assertIn("9a31f0acec1854d44e49a73fbf8017598151a583", rendered)
            self.assertIn("security-fix survival", rendered)
            self.assertIn("separate release gates", rendered)

    def test_m157_rejects_mutated_candidate_lock(self):
        with tempfile.TemporaryDirectory() as temporary:
            m157, provenance, path = self.write_m157_candidate_fixture(Path(temporary))
            lock = MODULE.load_json(path)
            m157.verify_lock(lock, provenance, ROOT)
            lock["sourceContractSHA256"] = "0" * 64
            path.write_text(json.dumps(lock))
            with self.assertRaisesRegex(
                MODULE.RuntimeNoticesError, "Chromium 157 source evidence verification failed"
            ):
                MODULE.render_m154_notices(
                    project_root=ROOT,
                    runtime_lock=path,
                    source_provenance=provenance,
                )

    def test_chromium_15680_uses_its_dedicated_source_qualified_notice_route(self):
        text = SCRIPT.read_text(encoding="utf-8")
        self.assertIn('if version == "156.0.8078.80":', text)
        self.assertIn("from chromium_15680_release_evidence import verify_lock", text)
        self.assertIn('"156.0.8078.80"}', text)

    def test_m155_default_check_uses_new_major_and_preserves_m154_notices(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "runtime").mkdir()
            (root / "docs").mkdir()
            (root / "runtime/fingerprint-chromium.lock.json").write_text(json.dumps({
                "fingerprintChromium": {"chromiumVersion": "155.0.8059.40"}}))
            old = root / "docs/RUNTIME_INTEGRATION_NOTICES_154.md"
            old.write_text("immutable old notices")
            (root / "docs/RUNTIME_INTEGRATION_NOTICES_155.md").write_text("new notices")
            with patch.object(sys, "argv", [str(SCRIPT), "--project-root", str(root), "--check"]), \
                 patch.object(MODULE, "render_notices", return_value="new notices"):
                self.assertEqual(MODULE.main(), 0)
            self.assertEqual(old.read_text(), "immutable old notices")

    def test_m154_candidate_has_own_source_and_preserves_public_notices(self) -> None:
        published = ROOT / "docs/RUNTIME_INTEGRATION_NOTICES.md"
        before = published.read_bytes()
        rendered = MODULE.render_m154_notices(
            project_root=ROOT, runtime_lock=ROOT / "runtime/fingerprint-chromium-154.lock.json")
        self.assertIn("Chromium: `154.0.8037.93`", rendered)
        self.assertNotIn("series.json", rendered)
        self.assertIn("separate release gates", rendered)
        self.assertEqual(before, published.read_bytes())

    def test_m154_rejects_contract_substitution(self) -> None:
        lock = MODULE.load_json(ROOT / "runtime/fingerprint-chromium-154.lock.json")
        lock["sourceContractSHA256"] = "0" * 64
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "candidate.json"
            path.write_text(json.dumps(lock))
            with self.assertRaisesRegex(MODULE.RuntimeNoticesError, "SHA-256 mismatch"):
                MODULE.render_m154_notices(project_root=ROOT, runtime_lock=path)

    def test_checked_in_notices_equal_fresh_public_metadata_render(self) -> None:
        runtime_lock = MODULE.load_json(ROOT / "runtime/fingerprint-chromium.lock.json")
        if runtime_lock["fingerprintChromium"]["chromiumVersion"] == "157.0.8103.39":
            return  # M157 source-only locks render only into the exact candidate compliance bundle.
        rendered = MODULE.render_notices(project_root=ROOT)
        if runtime_lock["fingerprintChromium"]["chromiumVersion"] == "156.0.8078.74":
            # The checked-in M156 document describes the historic .12 build;
            # the .74 candidate has its own pinned source provenance.
            self.assertEqual(rendered, MODULE.render_m154_notices(
                project_root=ROOT, runtime_lock=ROOT / "runtime/fingerprint-chromium.lock.json"))
            self.assertIn("Chromium: `156.0.8078.74`", rendered)
            self.assertIn("156.0.8078.12", (ROOT / "docs/RUNTIME_INTEGRATION_NOTICES_156.md").read_text())
            return
        if runtime_lock["fingerprintChromium"]["chromiumVersion"] in {"154.0.8037.93", "154.0.8037.98", "155.0.8059.40", "156.0.8078.12"}:
            self.assertEqual(rendered, (ROOT / ("docs/RUNTIME_INTEGRATION_NOTICES_"+runtime_lock["fingerprintChromium"]["chromiumVersion"].split(".")[0]+".md")).read_text())
            self.assertEqual(rendered, MODULE.render_m154_notices(
                project_root=ROOT, runtime_lock=ROOT / "runtime/fingerprint-chromium.lock.json"))
            self.assertIn(f"Chromium: `{runtime_lock['fingerprintChromium']['chromiumVersion']}`", rendered)
            return
        if runtime_lock.get("variant") == "recipient-privacy-policy-v1":
            self.assertEqual(rendered, (ROOT / "docs/RUNTIME_INTEGRATION_NOTICES_PRIVACY_V1.md").read_text())
            self.assertIn("MPL-2.0", rendered)
            self.assertIn("GPL-3.0", rendered)
            self.assertIn("RELINK_PRIVACY_V1.md", rendered)
            return
        checked_in = (
            ROOT / "docs" / "RUNTIME_INTEGRATION_NOTICES.md"
        ).read_text(encoding="utf-8")
        runtime_lock = MODULE.load_json(
            ROOT / "runtime" / "fingerprint-chromium.lock.json"
        )
        source_contract = MODULE.load_json(
            ROOT / "runtime" / "chromium-152-source-contract.json"
        )
        chromium_version = runtime_lock["fingerprintChromium"][
            "chromiumVersion"
        ]
        common_commit = runtime_lock["commonChromium"]["commit"]
        packaging_commit = runtime_lock["macPackaging"]["commit"]

        self.assertEqual(rendered, checked_in)
        self.assertIn(f"Chromium: `{chromium_version}`", rendered)
        self.assertIn(
            "Source contract binary binding: `pending-new-build`", rendered
        )
        self.assertIn(
            f"Source contract candidate: `{source_contract['targetChromiumVersion']}`",
            rendered,
        )
        self.assertIn(common_commit, rendered)
        self.assertIn(packaging_commit, rendered)
        self.assertIn("Owned patchset status: `release-ready`", rendered)
        self.assertNotIn("25 July 2026", rendered)

    def test_schema_four_nested_packaging_license_is_runtime_bound(self) -> None:
        expected = ROOT / "runtime/fingerprint-chromium-153.lock.json"
        runtime_lock = MODULE.load_json(expected)
        license_sha256 = hashlib.sha256((ROOT / "runtime/licenses/ungoogled-chromium-macos-LICENSE").read_bytes()).hexdigest()
        runtime_lock["macPackaging"]["criticalFiles"] = {"LICENSE": license_sha256}
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Path(temporary)
            shutil.copytree(ROOT / "runtime", fixture / "runtime")
            (fixture / "runtime/fingerprint-chromium.lock.json").write_text(json.dumps(runtime_lock))
            rendered = MODULE.render_notices(project_root=fixture)
        packaging = runtime_lock["macPackaging"]
        license_sha256 = packaging["criticalFiles"]["LICENSE"]
        self.assertIn(f"License SHA-256: `{license_sha256}`", rendered)

    def test_source_candidate_must_remain_pending_until_runtime_promotion(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Path(temporary)
            shutil.copytree(ROOT / "runtime", fixture / "runtime")
            runtime_lock_path = (
                fixture / "runtime" / "fingerprint-chromium.lock.json"
            )
            runtime_lock = MODULE.load_json(runtime_lock_path)
            runtime_lock["fingerprintChromium"]["chromiumVersion"] = (
                "151.0.7922.108"
            )
            # Current locks use the M156 schema. This negative test exercises
            # the legacy source-candidate branch, so supply its required shape.
            runtime_lock["macPackaging"] = {}
            runtime_lock["commonChromium"] = {}
            runtime_lock_path.write_text(
                json.dumps(runtime_lock),
                encoding="utf-8",
            )
            contract_path = (
                fixture / "runtime" / "chromium-152-source-contract.json"
            )
            contract = MODULE.load_json(contract_path)
            contract["binaryBindingStatus"] = "bound-to-binary"
            contract_path.write_text(
                json.dumps(contract),
                encoding="utf-8",
            )

            with self.assertRaisesRegex(
                MODULE.RuntimeNoticesError,
                "only while its binary binding is pending-new-build",
            ):
                MODULE.render_notices(project_root=fixture)

    def test_changed_locked_license_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Path(temporary)
            shutil.copytree(ROOT / "runtime", fixture / "runtime")
            # M154 binds its license in the lock. M156 instead verifies the
            # bundled license against the preserved built-source proof during
            # packaging; it does not declare a license hash in this lock.
            shutil.copyfile(
                fixture / "runtime/fingerprint-chromium-154.lock.json",
                fixture / "runtime/fingerprint-chromium.lock.json",
            )
            chromium_license = fixture / "runtime" / "licenses" / "Chromium-LICENSE"
            chromium_license.write_text(
                chromium_license.read_text(encoding="utf-8") + "\ndrift\n",
                encoding="utf-8",
            )

            with self.assertRaisesRegex(
                MODULE.RuntimeNoticesError,
                "license SHA-256 mismatch",
            ):
                MODULE.render_notices(project_root=fixture)

    def test_integrated_packager_checks_generated_notices(self) -> None:
        packager = (
            ROOT / "scripts" / "package-integrated-app.sh"
        ).read_text(encoding="utf-8")
        check = "generate-runtime-integration-notices.py\" --check"
        copy = 'docs/RUNTIME_INTEGRATION_NOTICES.md"'

        self.assertIn(check, packager)
        self.assertIn(copy, packager)
        self.assertLess(packager.index(check), packager.index(copy))


if __name__ == "__main__":
    unittest.main()
