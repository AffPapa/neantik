import unittest
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = PROJECT_ROOT / "scripts" / "build-runtime.sh"


class BuildRuntimeScriptTests(unittest.TestCase):
    def test_verifies_unpacked_chromium_source_version(self) -> None:
        script = SCRIPT.read_text(encoding="utf-8")

        self.assertIn("verify_source_version()", script)
        self.assertIn('"$SOURCE_DIR/chrome/VERSION"', script)
        self.assertIn('"$actual_version" != "$EXPECTED_CHROMIUM_VERSION"', script)
        self.assertIn("Chromium source version mismatch.", script)

    def test_source_version_gate_runs_for_fresh_and_resumed_source(self) -> None:
        script = SCRIPT.read_text(encoding="utf-8")

        resumed_block = script.split('if [[ -f "$SOURCE_STAMP" ]]', 1)[1].split("return", 1)[0]
        fresh_block = script.split('"$BUILD_ROOT/ungoogled-chromium/utils/domain_substitution.py"', 1)[1].split(
            'printf \'%s\\n\'',
            1,
        )[0]

        self.assertIn("verify_source_version", resumed_block)
        self.assertIn("verify_source_version", fresh_block)

    def test_owned_rebase_stamp_binds_manifest_and_has_explicit_recovery(self) -> None:
        script = SCRIPT.read_text(encoding="utf-8")

        self.assertIn("patch_manifest_sha256=", script)
        self.assertIn("NEANTIK_RECOVER_SOURCE_STAMP", script)
        self.assertIn("apply-neantik-patchset.py", script)
        self.assertIn("write_owned_source_stamp", script)
        self.assertIn(
            "after an intentional patch-manifest update",
            script,
        )

    def test_owned_rebase_applies_and_rechecks_generated_tuple_layer(self) -> None:
        script = SCRIPT.read_text(encoding="utf-8")
        owned_layer = script.split(
            "apply_owned_source_layers()",
            1,
        )[1].split("prepare_source()", 1)[0]

        self.assertIn("apply-neantik-patchset.py", owned_layer)
        self.assertEqual(
            owned_layer.count("apply-owned-runtime-device-tuples.py"),
            2,
        )
        self.assertIn("--check", owned_layer)
        self.assertGreaterEqual(
            script.count("apply_owned_source_layers"),
            6,
        )

    def test_owned_rebase_verifies_rust_archive_missing_upstream_hash(self) -> None:
        script = SCRIPT.read_text(encoding="utf-8")
        lock = (
            PROJECT_ROOT / "runtime" / "chromium-151-toolchain-lock.json"
        ).read_text(encoding="utf-8")

        self.assertIn("chromium-151-toolchain-lock.json", script)
        self.assertIn("Locked Rust toolchain archive verified.", script)
        self.assertIn(
            "8b5933fa6319cc2b4a83098562731eff4c16cb982be44282aef51c17a43fe7e6",
            lock,
        )

    def test_owned_rebase_installs_exact_dawn_go_toolchain(self) -> None:
        script = SCRIPT.read_text(encoding="utf-8")
        lock = (
            PROJECT_ROOT / "runtime" / "chromium-151-toolchain-lock.json"
        ).read_text(encoding="utf-8")

        self.assertIn("prepare_owned_dawn_go()", script)
        self.assertIn("chrome-infra-packages.appspot.com/client", script)
        self.assertIn("dawnGo.clientSHA256", script)
        self.assertIn("dawnGo.instanceId", script)
        self.assertIn("Locked Dawn Go toolchain verified.", script)
        self.assertIn('"version": "1.25.0"', lock)
        self.assertIn(
            '"instanceId": "3JX2vzvi6MjGUTHLmAins8zodX5IxdLkTI8TdMh90gIC"',
            lock,
        )

    def test_exports_source_provenance_before_ninja_compile(self) -> None:
        script = SCRIPT.read_text(encoding="utf-8")

        export_index = script.index("export-runtime-source-provenance.py")
        verify_index = script.index("verify-runtime-source-provenance.py")
        compile_index = script.index("ninja -C out/Default")
        self.assertLess(export_index, compile_index)
        self.assertLess(verify_index, compile_index)
        self.assertIn('SOURCE_PROVENANCE="$BUILD_DIR/source-provenance.json"', script)

    def test_official_lite_archive_build_contract_is_release_required(self) -> None:
        script = SCRIPT.read_text(encoding="utf-8")
        manifest = (
            PROJECT_ROOT / "runtime" / "nevision-patches" / "series.json"
        ).read_text(encoding="utf-8")

        self.assertIn("apply-neantik-patchset.py", script)
        self.assertIn("official-lite-archive-build-contract", manifest)

    def test_shipping_build_does_not_compile_unused_chromedriver(self) -> None:
        script = SCRIPT.read_text(encoding="utf-8")

        self.assertIn('ninja -C out/Default -j"$jobs" chrome', script)
        self.assertNotIn("chrome chromedriver", script)

    def test_go_generators_keep_cache_inside_build_root(self) -> None:
        script = SCRIPT.read_text(encoding="utf-8")

        self.assertIn('GO_CACHE_DIR="$BUILD_DIR/go-build-cache"', script)
        self.assertIn('GO_PATH_DIR="$BUILD_DIR/go-path"', script)
        self.assertIn('export GOCACHE="$GO_CACHE_DIR"', script)
        self.assertIn('export GOPATH="$GO_PATH_DIR"', script)

    def test_each_compile_attempt_has_a_clean_preserved_log(self) -> None:
        script = SCRIPT.read_text(encoding="utf-8")

        self.assertIn("Previous build log preserved:", script)
        self.assertIn('previous_build_log="$BUILD_LOG.', script)
        self.assertIn(': > "$BUILD_LOG"', script)
        self.assertIn('tee "$BUILD_LOG"', script)
        self.assertNotIn('tee -a "$BUILD_LOG"', script)


if __name__ == "__main__":
    unittest.main()
