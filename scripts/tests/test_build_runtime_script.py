import hashlib
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = PROJECT_ROOT / "scripts" / "build-runtime.sh"


class BuildRuntimeScriptTests(unittest.TestCase):
    def test_resumed_dawn_go_ensure_requests_integrity_before_using_binary(self) -> None:
        script = SCRIPT.read_text(encoding="utf-8")
        function = "prepare_owned_dawn_go() {" + script.split(
            "prepare_owned_dawn_go() {", 1
        )[1].split("\nrun_packaging_resource_unpack()", 1)[0]
        with tempfile.TemporaryDirectory(prefix="neantik-cipd-resume-") as directory:
            root = Path(directory)
            tools = root / "tools"
            tools.mkdir()
            dawn = root / "src/third_party/dawn"
            go_root = dawn / "tools/golang/mac-arm64"
            (go_root / "bin").mkdir(parents=True)
            (go_root / ".cipd").mkdir()
            (go_root / ".cipd/installed-metadata").write_text("already satisfied\n")
            (dawn / "DEPS").write_text("'dawn_go_version': 'test-deps'\n")
            plutil = tools / "plutil"
            plutil.write_text("""#!/bin/sh
case "$2" in
  dawnGo.package) echo test/package ;;
  dawnGo.instanceId) echo pinned-instance ;;
  dawnGo.clientRevision) echo pinned-client ;;
  dawnGo.clientSHA256) echo "$TEST_CLIENT_SHA256" ;;
  dawnGo.version) echo 1.25.0 ;;
  dawnGo.depsVersion) echo test-deps ;;
  *) exit 71 ;;
esac
""")
            plutil.chmod(0o755)
            cipd = tools / "cipd"
            cipd.write_text("""#!/bin/sh
[ "$1" = ensure ] && [ "$2" = -root ] && [ "$4" = -ensure-file ] && [ "$5" = - ] || exit 72
IFS= read -r mode
IFS= read -r binding
[ "$mode" = '$ParanoidMode CheckIntegrity' ] || exit 73
[ "$binding" = 'test/package pinned-instance' ] || exit 74
cp "$TEST_VERIFIED_GO" "$3/bin/go"
chmod 755 "$3/bin/go"
""")
            cipd.chmod(0o755)
            verified_go = root / "verified-go"
            verified_go.write_text("#!/bin/sh\necho 'go version go1.25.0 darwin/arm64'\n")
            environment = {
                **os.environ,
                "PATH": f"{tools}:/usr/bin:/bin",
                "SOURCE_MODE": "owned-rebase", "SOURCE_DIR": str(root / "src"),
                "TOOLS_DIR": str(tools), "TOOLCHAIN_LOCK": str(root / "unused-lock.json"),
                "TEST_CLIENT_SHA256": hashlib.sha256(cipd.read_bytes()).hexdigest(),
                "TEST_VERIFIED_GO": str(verified_go),
            }
            go_binary = go_root / "bin/go"
            for damaged in (False, True):
                with self.subTest(damaged=damaged):
                    if damaged:
                        go_binary.write_text("#!/bin/sh\nexit 79\n")
                    result = subprocess.run(
                        ["/bin/bash", "-c", "set -euo pipefail\n" + function + "\nprepare_owned_dawn_go\n"],
                        env=environment, text=True, capture_output=True, timeout=10,
                    )
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn("Locked Dawn Go toolchain verified.", result.stdout)
                    self.assertEqual(go_binary.read_bytes(), verified_go.read_bytes())

    def run_isolation_guard(self, root: Path, tools: Path, phase: str = "prepare") -> subprocess.CompletedProcess:
        tools.mkdir(exist_ok=True)
        for name, body in {
            "uname": "echo arm64\n",
            "plutil": "echo PINNED_SOURCE_GATE_REACHED >&2\nexit 97\n",
        }.items():
            tool = tools / name
            tool.write_text("#!/bin/sh\n" + body, encoding="utf-8")
            tool.chmod(0o755)
        return subprocess.run(
            ["/bin/bash", str(SCRIPT), str(root), phase],
            env={**os.environ, "DEVELOPER_DIR": "/unused-test-developer", "PATH": f"{tools}:/usr/bin:/bin"},
            text=True, capture_output=True, timeout=10,
        )

    def make_source_pair(self, root: Path) -> None:
        (root / ".git").mkdir(parents=True)
        (root / "ungoogled-chromium" / ".git").mkdir(parents=True)

    def test_shell_rejects_ancestor_dependencies_before_pinned_source_gate(self) -> None:
        with tempfile.TemporaryDirectory(prefix="neantik-isolation-") as directory:
            parent = Path(directory)
            root = parent / "workspace with spaces" / "runtime"
            self.make_source_pair(root)
            dependency = parent / "node_modules"
            dependency.mkdir()
            for phase in ("prepare", "configure", "build", "all"):
                with self.subTest(phase=phase):
                    result = self.run_isolation_guard(root, parent / "tools", phase)
                    self.assertEqual(result.returncode, 65, result.stderr)
                    self.assertIn("isolated build root", result.stderr)
                    self.assertIn(str(dependency.resolve()), result.stderr)
                    self.assertNotIn("PINNED_SOURCE_GATE_REACHED", result.stderr)
                    self.assertFalse((root / "build").exists())
                    self.assertTrue(dependency.is_dir())

    def test_shell_checks_physical_ancestors_through_symlink(self) -> None:
        with tempfile.TemporaryDirectory(prefix="neantik-isolation-") as directory:
            parent = Path(directory)
            root = parent / "contaminated" / "runtime"
            self.make_source_pair(root)
            (root.parent / "node_modules").mkdir()
            alias = parent / "clean-looking-alias"
            alias.symlink_to(root, target_is_directory=True)
            result = self.run_isolation_guard(alias, parent / "tools")
            self.assertEqual(result.returncode, 65, result.stderr)
            self.assertIn(str((root.parent / "node_modules").resolve()), result.stderr)

    def test_shell_allows_clean_root_and_bundled_source_dependencies(self) -> None:
        with tempfile.TemporaryDirectory(prefix="neantik-isolation-") as directory:
            parent = Path(directory)
            root = parent / "runtime"
            self.make_source_pair(root)
            for bundled in (False, True):
                with self.subTest(bundled=bundled):
                    if bundled:
                        (root / "build/src/third_party/node/node_modules").mkdir(parents=True)
                    result = self.run_isolation_guard(root, parent / "tools")
                    self.assertEqual(result.returncode, 97, result.stderr)
                    self.assertIn("PINNED_SOURCE_GATE_REACHED", result.stderr)
                    self.assertNotIn("requires isolation", result.stderr)

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
            PROJECT_ROOT / "runtime" / "chromium-152-toolchain-lock.json"
        ).read_text(encoding="utf-8")

        self.assertIn("chromium-152-toolchain-lock.json", script)
        self.assertIn("Locked Rust toolchain archive verified.", script)
        self.assertIn(
            "8b5933fa6319cc2b4a83098562731eff4c16cb982be44282aef51c17a43fe7e6",
            lock,
        )

    def test_owned_rebase_installs_exact_dawn_go_toolchain(self) -> None:
        script = SCRIPT.read_text(encoding="utf-8")
        lock = (
            PROJECT_ROOT / "runtime" / "chromium-152-toolchain-lock.json"
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

    def test_build_does_not_consume_an_unpinned_macos_pgo_profile(self) -> None:
        script = SCRIPT.read_text(encoding="utf-8")

        self.assertIn('print "chrome_pgo_phase=0"', script)
        self.assertIn("pgo_written", script)

    def test_shipping_build_avoids_macos27_llvm_strip_corruption(self) -> None:
        script = SCRIPT.read_text(encoding="utf-8")

        self.assertIn("llvm-strip 22", script)
        self.assertIn("macOS 27 dyld", script)
        self.assertIn("'enable_stripping=false'", script)
        self.assertIn('"stripping=disabled"', script)

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
