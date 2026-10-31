import unittest
import plistlib
import os
from pathlib import Path
import subprocess
import tempfile


SCRIPTS = Path(__file__).resolve().parents[1]
PREPARE = SCRIPTS / "prepare-direct-runtime-candidate.sh"
PREPARE_MANAGER = SCRIPTS / "prepare-direct-manager-update.sh"
PACKAGE_APP = SCRIPTS / "package-app.sh"
RELEASE = SCRIPTS / "release-direct.sh"
NOTARIZE = SCRIPTS / "notarize-direct-candidate.sh"
NOTARY_TRANSACTION = SCRIPTS / "notarize_direct_transaction.py"
ENROLL = SCRIPTS / "enroll-direct-fingerprint-authority.sh"
INTEGRATED_VERIFIER = SCRIPTS / "verify-integrated-release.sh"
DIRECT_ENTITLEMENTS = SCRIPTS.parent / "runtime/neantik-direct-entitlements.plist"
RELEASE_COMMAND = SCRIPTS / "Run-NeAntik-Release.command"
RELEASE_ENTRYPOINT = SCRIPTS.parent / "Release-NeAntik.command"


class ReleaseDirectScriptTests(unittest.TestCase):
    def test_runtime_preparation_preserves_explicit_backup_selection(self) -> None:
        text = PREPARE.read_text(encoding="utf-8")
        self.assertNotIn('NEANTIK_BROWSER_DATA_BACKUP_ENABLED=0 NEANTIK_DIRECT_PROVISIONING_PROFILE=""', text)
        self.assertIn('"$PROJECT_DIR/scripts/package-integrated-app.sh"', text)

    def test_prepared_candidate_without_binding_is_preserved_before_rebuild(self) -> None:
        inner = (SCRIPTS / "Run-NeAntik-Release.command").read_text(encoding="utf-8")
        start = inner.index("# A freshly prepared runtime candidate needs")
        end = inner.index('mkdir -p "$ATTEMPT_STATE_ROOT"', start)
        guard = inner[start:end]
        with tempfile.TemporaryDirectory(prefix="neantik-unbound-candidate-") as temporary:
            root = Path(temporary)
            app = root / "NeAntik.app"
            app.mkdir()
            marker = app / "retain"
            marker.write_text("candidate intact")
            manifest = root / "manifest.json"
            manifest.write_text("candidate manifest intact")
            env = {**os.environ, "APP_PATH": str(app), "CANDIDATE_MANIFEST": str(manifest),
                   "CANDIDATE_SOURCE_BINDING": str(root / "binding.json")}
            result = subprocess.run(["/bin/zsh", "-c", guard], env=env,
                                    text=True, capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 65, result.stderr)
            self.assertIn("no source binding", result.stderr)
            self.assertEqual(marker.read_text(), "candidate intact")
            self.assertEqual(manifest.read_text(), "candidate manifest intact")

    def test_runtime_preparation_preserves_existing_or_partial_apps(self) -> None:
        with tempfile.TemporaryDirectory(prefix="neantik-preserve-fixture-") as temporary:
            root = Path(temporary).resolve()
            project = root / "project"
            scripts = project / "scripts"
            scripts.mkdir(parents=True)
            dist = project / "dist"
            dist.mkdir()
            prepare = scripts / PREPARE.name
            prepare.write_bytes(PREPARE.read_bytes())
            source = root / "src"
            source.mkdir()
            runtime = source / "NeAntik Browser.app"
            runtime.mkdir()
            args = source / "args.gn"
            args.write_text("angle_enable_metal = true\n")
            lock = root / "runtime-candidate-lock.json"
            lock.write_text("{}")
            for name in ("NeAntik.app", "NeAntik-Integrated.app"):
                with self.subTest(name=name):
                    app = dist / name
                    app.mkdir()
                    marker = app / "retain"
                    marker.write_text("preserve exact candidate")
                    result = subprocess.run(
                        ["/bin/zsh", str(prepare), str(runtime), str(args), str(source), str(lock)],
                        capture_output=True, text=True, timeout=10,
                    )
                    self.assertEqual(result.returncode, 65, result.stderr)
                    self.assertIn("previous prepared or partial app exists", result.stderr)
                    self.assertEqual(marker.read_text(), "preserve exact candidate")
                    marker.unlink()
                    app.rmdir()

    def test_runtime_preparation_checks_resources_before_build_and_enrollment(self) -> None:
        text = PREPARE.read_text(encoding="utf-8")
        check = 'python3 -B "$PROJECT_DIR/scripts/native-qa-readiness.py" --check'
        self.assertEqual(text.count(check), 2)
        first = text.index(check)
        second = text.index(check, first + len(check))
        self.assertLess(first, text.index('"$NINJA_BIN" -C "$CHROMIUM_OUT_DIR"'))
        self.assertLess(second, text.index('"$PROJECT_DIR/scripts/enroll-direct-fingerprint-authority.sh"'))

    def test_missing_build_log_refuses_ninja_and_preserves_output(self) -> None:
        script = PREPARE.read_text(encoding="utf-8")
        start = script.index('  NINJA_BIN="$SOURCE_ROOT/third_party/ninja/ninja"')
        end = script.index('\nfi\nif [[ "$(plutil', start)
        guard = script[start:end]
        with tempfile.TemporaryDirectory(prefix="neantik-missing-ninja-log-") as temporary:
            root = Path(temporary)
            ninja = root / "src/third_party/ninja/ninja"
            ninja.parent.mkdir(parents=True)
            marker = root / "invoked"
            ninja.write_text('#!/bin/sh\ntouch "$MARKER"\n')
            ninja.chmod(0o755)
            output = root / "out"
            output.mkdir()
            retained = output / "retained"
            retained.write_text("keep")
            binaries = root / "bin"
            binaries.mkdir()
            plutil = binaries / "plutil"
            plutil.write_text('#!/bin/sh\nprintf "156.0.8078.74\n"\n')
            plutil.chmod(0o755)
            env = {**os.environ, "SOURCE_ROOT": str(root / "src"),
                   "CHROMIUM_OUT_DIR": str(output), "MARKER": str(marker),
                   "CANDIDATE_LOCK": str(root / "lock.json"), "PATH": str(binaries) + os.pathsep + os.environ["PATH"]}
            result = subprocess.run(["/bin/zsh", "-c", guard], env=env,
                                    capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 65, result.stderr)
            self.assertIn("build log is unavailable", result.stderr)
            self.assertFalse(marker.exists())
            self.assertEqual(retained.read_text(), "keep")

    def test_runtime_preparation_refuses_warning_before_ninja_or_signing(self) -> None:
        with tempfile.TemporaryDirectory(prefix="neantik-admission-fixture-") as temporary:
            root = Path(temporary).resolve()
            scripts, binaries, stage = root / "project/scripts", root / "bin", root / "stage"
            scripts.mkdir(parents=True)
            binaries.mkdir()
            (stage / "src").mkdir(parents=True)
            app = stage / "src/NeAntik Browser.app"
            app.mkdir()
            args = stage / "src/args.gn"
            args.write_text("angle_enable_metal = true\n", encoding="utf-8")
            for relative in ("tools/licenses/licenses.py", "gen/components/resources/about_credits.html"):
                compliance_input = stage / "src" / relative
                compliance_input.parent.mkdir(parents=True, exist_ok=True)
                compliance_input.write_text("synthetic required input\n", encoding="utf-8")
            lock = stage / "runtime-candidate-lock.json"
            lock.write_text("{}", encoding="utf-8")
            (stage / "source-provenance.json").write_text("{}", encoding="utf-8")
            prepare = scripts / PREPARE.name
            prepare.write_bytes(PREPARE.read_bytes())
            log = root / "calls.log"
            python = binaries / "python3"
            python.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$CALL_LOG"\ncase "$*" in *native-qa-readiness.py*) exit 75;; esac\nexit 0\n')
            python.chmod(0o755)
            plutil = binaries / "plutil"
            plutil.write_text('#!/bin/sh\nprintf "156.0.8078.80\\n"\n')
            plutil.chmod(0o755)
            for name in ("verify-runtime-source-provenance.py", "verify-runtime-candidate-lock.py",
                         "verify-runtime-security-baseline.py", "verify-direct-version-bump.py",
                         "verify-direct-telemetry-disabled.py", "verify-direct-update-policy.py",
                         "verify-browser-identity-issuance.py", "verify-public-fingerprint-corpus.py",
                         "preflight-distribution.sh"):
                stub = scripts / name
                stub.write_text('#!/bin/sh\nexit 0\n')
                stub.chmod(0o755)
            for name in ("ninja", "codesign"):
                stub = binaries / name
                stub.write_text('#!/bin/sh\nprintf "forbidden-native-action\\n" >> "$CALL_LOG"\nexit 99\n')
                stub.chmod(0o755)
            env = {**os.environ, "PATH": str(binaries) + os.pathsep + os.environ["PATH"],
                   "CALL_LOG": str(log), "NEANTIK_RELEASE_CHANNEL": "public-alpha",
                   "NEANTIK_SIGNING_IDENTITY": "synthetic"}
            result = subprocess.run(["/bin/zsh", str(prepare), str(app), str(args),
                                     str(stage / "src"), str(lock)], env=env,
                                    capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 75, result.stderr)
            calls = log.read_text(encoding="utf-8")
            self.assertIn("native-qa-readiness.py", calls)
            self.assertNotIn("forbidden-native-action", calls)

    def test_1_0_wrapper_requires_production_channel(self) -> None:
        text = RELEASE_ENTRYPOINT.read_text(encoding="utf-8")
        self.assertIn('if [[ "$VERSION" == "1.0.0" ]]; then', text)
        self.assertIn('"$NEANTIK_RELEASE_CHANNEL" != "production"', text)
        self.assertIn("export NEANTIK_RELEASE_CHANNEL=production", text)

    def test_production_channel_selects_production_webkit_build_mode(self) -> None:
        for script in (PACKAGE_APP, PREPARE_MANAGER):
            with self.subTest(script=script.name):
                self.assertIn('source "$PROJECT_DIR/scripts/resolve-webkit-proxy-build-mode.sh"',
                              script.read_text(encoding="utf-8"))

        helper = SCRIPTS / "resolve-webkit-proxy-build-mode.sh"
        cases = (
            ({"NEANTIK_RELEASE_CHANNEL": "production"}, 0, "production"),
            ({"NEANTIK_RELEASE_CHANNEL": "production",
              "NEANTIK_WEBKIT_PROXY_BUILD_MODE": "qualification"}, 64, None),
            ({"NEANTIK_RELEASE_CHANNEL": "public-alpha",
              "NEANTIK_WEBKIT_PROXY_BUILD_MODE": "production"}, 64, None),
            ({"NEANTIK_RELEASE_CHANNEL": "public-alpha"}, 0, "unset"),
        )
        for environment, expected_code, expected_mode in cases:
            with self.subTest(environment=environment):
                child_env = os.environ.copy()
                child_env.pop("NEANTIK_RELEASE_CHANNEL", None)
                child_env.pop("NEANTIK_WEBKIT_PROXY_BUILD_MODE", None)
                child_env.update(environment)
                result = subprocess.run(
                    ["/bin/zsh", "-c",
                     'source "$1" || exit $?; print -r -- "${NEANTIK_WEBKIT_PROXY_BUILD_MODE:-unset}"',
                     "zsh", str(helper)],
                    env=child_env, text=True, capture_output=True, timeout=10)
                self.assertEqual(result.returncode, expected_code, result.stderr)
                if expected_mode is not None:
                    self.assertEqual(result.stdout.strip(), expected_mode)

    def test_owned_webkit_release_switch_remains_fail_closed_with_actionable_reason(self) -> None:
        text = PACKAGE_APP.read_text(encoding="utf-8")
        self.assertIn('1) echo "Owned WebKit is not release-enabled:', text)
        self.assertIn("license closure", text)
        self.assertIn("per-profile no-Direct network proof", text)
        self.assertIn("exit 78", text)
        self.assertNotIn("separately linked runtime host", text)

    def test_finder_release_wrapper_uses_the_current_neantik_identity(self) -> None:
        text = RELEASE_COMMAND.read_text(encoding="utf-8")
        self.assertIn(
            'NEANTIK_SIGNING_IDENTITY:-474F7C78F33EE324C24F6F5AE0443EB713E85E60',
            text,
        )

    def test_device_memory_control_blocks_release_before_gui_audit(self) -> None:
        text = RELEASE_COMMAND.read_text(encoding="utf-8")
        control = 'node "$PROJECT_DIR/scripts/verify-device-memory-coherence.mjs" "$APP_PATH"'
        self.assertIn(control, text)
        self.assertLess(text.index(control), text.index('echo "[2/4] Проверяю изоляцию'))

    def test_bridge_manager_keeps_existing_app_id_and_no_unqualified_media(self) -> None:
        claims = plistlib.loads(DIRECT_ENTITLEMENTS.read_bytes())
        self.assertEqual(
            claims,
            {"com.apple.application-identifier":
             "H6VGU2M6JD.app.neantik.desktop"},
        )

    def test_release_packaging_resolves_current_swift_bin_path(self) -> None:
        stale_path = ".build/arm64-apple-macosx/release/NeAntik"

        for script in (PACKAGE_APP, PREPARE_MANAGER):
            text = script.read_text(encoding="utf-8")
            self.assertIn("--show-bin-path", text)
            self.assertIn('MANAGER_BINARY="$BIN_PATH/NeAntik"', text)
            self.assertIn('cp "$MANAGER_BINARY"', text)
            self.assertNotIn(stale_path, text)

    def test_manager_debug_paths_are_removed_before_signing(self) -> None:
        for script, binary, signature in (
            (PACKAGE_APP, '$MACOS_DIR/NeAntik', 'codesign --force'),
            (PREPARE_MANAGER, '$CANDIDATE_APP/Contents/MacOS/NeAntik', 'codesign \\\n'),
        ):
            with self.subTest(script=script.name):
                text = script.read_text(encoding="utf-8")
                strip = f'xcrun strip -S "{binary}"'
                self.assertIn(strip, text)
                self.assertLess(text.index(strip), text.index(signature))

    def test_prepare_builds_and_binds_one_exact_candidate(self) -> None:
        text = PREPARE.read_text(encoding="utf-8")
        self.assertIn('CANDIDATE_LOCK="$4"', text)
        self.assertIn("--source-root \"$SOURCE_ROOT\"", text)
        self.assertIn("--lock \"$CANDIDATE_LOCK\"", text)
        self.assertIn("angle_enable_metal=true", text)
        self.assertIn("verify-runtime-source-provenance.py", text)
        self.assertIn("verify-runtime-candidate-lock.py", text)
        self.assertIn("verify-runtime-security-baseline.py", text)
        self.assertIn("verify-direct-version-bump.py", text)
        self.assertIn("verify-direct-telemetry-disabled.py", text)
        self.assertIn("verify-direct-update-policy.py", text)
        self.assertIn("verify-public-fingerprint-corpus.py", text)
        self.assertIn("sign-runtime.sh", text)
        self.assertIn("verify-built-runtime.sh", text)
        self.assertIn("promote-runtime-candidate-lock.py", text)
        self.assertIn("--confirm-promote-source-lock", text)
        self.assertIn("generate-runtime-integration-notices.py", text)
        self.assertIn("package-integrated-app.sh", text)
        self.assertIn("enroll-direct-fingerprint-authority.sh", text)
        self.assertIn("direct-candidate-manifest.py", text)
        self.assertIn("--fingerprint-enrollment", text)
        self.assertIn("/usr/bin/mktemp -d", text)
        self.assertIn("fingerprint-enrollment.XXXXXX", text)
        self.assertIn('APP_PATH="$PROJECT_DIR/dist/NeAntik.app"', text)
        self.assertNotIn("notarytool submit", text)
        self.assertLess(
            text.index("sign-runtime.sh"),
            text.index("promote-runtime-candidate-lock.py"),
        )
        self.assertLess(
            text.index("promote-runtime-candidate-lock.py"),
            text.index("package-integrated-app.sh"),
        )
        self.assertLess(
            text.index("enroll-direct-fingerprint-authority.sh"),
            text.index("direct-candidate-manifest.py"),
        )

    def test_public_candidate_prep_cannot_bypass_owned_webkit_gate(self) -> None:
        text = PREPARE.read_text(encoding="utf-8")
        input_preflight = text.index('Owned WebKit is not release-enabled; direct candidate preparation refuses runtime injection.')
        runtime_provenance = text.index('scripts/runtime_build_path.py')
        self.assertLess(input_preflight, runtime_provenance)
        self.assertNotIn('package-webkit-host.py', text)
        self.assertIn('NEANTIK_OWNED_WEBKIT_HOST_BINARY', text)

    def test_chromium_15680_preparation_does_not_render_unrelated_default_notices(self) -> None:
        text = PREPARE.read_text(encoding="utf-8")
        branch = text.index('== "156.0.8078.80" ]]; then')
        packager = text.index('package-integrated-app.sh', branch)
        self.assertIn('Do not\n  # render the default notice file from the unrelated published runtime lock.', text[branch:packager])
        self.assertLess(branch, packager)
        self.assertIn('NEANTIK_OWNED_WEBKIT_FRAMEWORKS', text)
        verifier = INTEGRATED_VERIFIER.read_text(encoding="utf-8")
        self.assertIn('verify-webkit-host-pin.py" "$APP_PATH"', verifier)
        self.assertLess(verifier.index('verify-webkit-host-pin.py'), verifier.index('verify-release.sh'))
        self.assertIn('webkit_runtime_notices.py', verifier)

    def test_public_candidate_prep_refuses_runtime_injection_before_build(self) -> None:
        with tempfile.TemporaryDirectory(prefix="neantik-webkit-gate-") as temporary:
            root = Path(temporary)
            runtime = root / "NeAntik Browser.app"
            source = root / "chromium-source"
            runtime.mkdir()
            source.mkdir()
            args = root / "args.gn"
            lock = root / "runtime-lock.json"
            args.write_text("", encoding="utf-8")
            lock.write_text("{}\n", encoding="utf-8")
            environment = os.environ.copy()
            environment["NEANTIK_OWNED_WEBKIT_HOST_BINARY"] = str(root / "host")
            environment.pop("NEANTIK_OWNED_WEBKIT_FRAMEWORKS", None)

            result = subprocess.run(
                ["/bin/zsh", str(PREPARE), str(runtime), str(args), str(source), str(lock)],
                env=environment, capture_output=True, text=True, timeout=10,
            )

            self.assertEqual(result.returncode, 78, result.stdout + result.stderr)
            self.assertIn("refuses runtime injection", result.stderr)
            self.assertNotIn("runtime_build_path.py", result.stderr)

    def test_manager_candidate_enrolls_only_after_final_signature(self) -> None:
        text = PREPARE_MANAGER.read_text(encoding="utf-8")
        enrollment = text.index(
            "enroll-direct-fingerprint-authority.sh"
        )
        manifest = text.index("direct-candidate-manifest.py")
        final_signing = text.index('direct_backup_signing.py" sign')

        self.assertLess(final_signing, enrollment)
        self.assertLess(enrollment, manifest)
        self.assertIn("--fingerprint-enrollment", text)
        self.assertIn("/usr/bin/mktemp -d", text)
        self.assertIn("fingerprint-enrollment.XXXXXX", text)
        self.assertIn(
            "LOCAL QA ONLY: schema-3 release enrollment was intentionally skipped.",
            text,
        )

    def test_manager_only_update_preserves_verified_runtime_evidence(self) -> None:
        text = PREPARE_MANAGER.read_text(encoding="utf-8")

        self.assertIn("verify_reviewed_runtime_evidence", text)
        self.assertIn('--lock "$runtime_candidate_lock"', text)
        self.assertIn('runtime_candidate_lock="$(resolve_runtime_candidate_lock)"', text)
        self.assertIn("verify-packaged-runtime-report.py", text)
        self.assertIn("verify-runtime-compliance.sh", text)
        self.assertIn('direct_backup_signing.py" sign', text)
        for signing_script in (
            PACKAGE_APP,
            PREPARE,
        ):
            self.assertIn('direct_backup_signing.py" sign', signing_script.read_text(encoding="utf-8"))
        shared_signer = (SCRIPTS / "direct_backup_signing.py").read_text(encoding="utf-8")
        self.assertIn('runtime/neantik-direct-entitlements.plist', shared_signer)
        self.assertIn('verify-direct-provisioning-contract.py', shared_signer)
        verifier = (SCRIPTS / "verify-release.sh").read_text(
            encoding="utf-8"
        )
        self.assertIn('MANAGER_ENTITLEMENTS="$(codesign -d --entitlements -', verifier)
        self.assertIn('com.apple.developer.team-identifier', verifier)
        self.assertIn('-Xswiftc -debug-prefix-map', text)
        self.assertIn('-Xswiftc -file-prefix-map', text)
        self.assertIn('--scratch-path "$BUILD_SUPPORT_DIR/swift-build"', text)
        self.assertIn('-Xcc "-fdebug-prefix-map=$PROJECT_DIR=/NeAntikSource"', text)
        self.assertIn('SOURCE_PARENT="$(dirname "$PROJECT_DIR")"', text)
        self.assertIn('-Xswiftc "$SOURCE_PARENT=/NeAntikWorkspace"', text)
        self.assertIn('-Xcc "-fdebug-prefix-map=$SOURCE_PARENT=/NeAntikWorkspace"', text)
        self.assertIn("cmp -s", text)
        self.assertNotIn(
            '"$PROJECT_DIR/scripts/verify-built-runtime.sh" \\\n'
            '    "$CANDIDATE_RUNTIME" \\\n'
            '    "$evidence/runtime-verification.json"',
            text,
        )
        self.assertNotIn("rebind_runtime_compliance", text)

    def test_manager_only_update_selects_contract_for_packaged_runtime(self) -> None:
        text = PREPARE_MANAGER.read_text(encoding="utf-8")

        self.assertIn(
            'runtime_version="$(plutil -extract fingerprintChromium.chromiumVersion',
            text,
        )
        self.assertIn(
            'source_contract="$PROJECT_DIR/runtime/chromium-153-port-status.json"',
            text,
        )
        self.assertIn(
            'source_contract="$PROJECT_DIR/runtime/chromium-152-source-contract.json"',
            text,
        )
        self.assertIn(
            '154.0.8037.93)',
            text,
        )
        self.assertIn(
            'source_contract="$PROJECT_DIR/runtime/chromium-154-source-contract.json"',
            text,
        )
        self.assertIn(
            "refusing the historical M152 default",
            text,
        )
        self.assertIn('154.0.8037.98)', text)
        self.assertIn(
            'source_contract="$PROJECT_DIR/runtime/chromium-15498-source-contract.json"',
            text,
        )
        self.assertIn('packaged_contract_name="chromium-154-source-contract.json"', text)
        self.assertIn('"$source_contract:$evidence/$packaged_contract_name"', text)

    def test_integrated_verifier_dispatches_qualified_m154_without_fallback(self) -> None:
        text = INTEGRATED_VERIFIER.read_text(encoding="utf-8")

        self.assertIn(
            '[[ "$EXPECTED_RUNTIME_VERSION" == "154.0.8037.93" ]]',
            text,
        )
        self.assertIn(
            'SOURCE_PROVENANCE_FILE="$PROJECT_DIR/runtime/chromium-154-port-candidate.json"',
            text,
        )
        self.assertIn(
            'CANDIDATE_LOCK_FILE="$PROJECT_DIR/runtime/fingerprint-chromium-154.lock.json"',
            text,
        )
        self.assertIn(
            'SOURCE_CONTRACT_FILE="$PROJECT_DIR/runtime/chromium-154-source-contract.json"',
            text,
        )
        self.assertIn(
            'PACKAGED_SOURCE_CONTRACT="$EVIDENCE/chromium-154-source-contract.json"',
            text,
        )
        self.assertIn(
            "154.0.8037.58 is diagnostic-only and cannot be released.",
            text,
        )
        self.assertIn(
            '[[ "$EXPECTED_RUNTIME_VERSION" == 152.* ||',
            text,
        )

    def test_manager_only_update_preserves_russian_bundle_contract(self) -> None:
        prepare = PREPARE_MANAGER.read_text(encoding="utf-8")
        verifier = INTEGRATED_VERIFIER.read_text(encoding="utf-8")

        for resource in ("InfoPlist.strings", "Localizable.strings"):
            self.assertIn(
                f'"$PROJECT_DIR/Resources/ru.lproj/{resource}"',
                prepare,
            )
            self.assertIn(resource, verifier)
        self.assertIn(
            '"$CANDIDATE_APP/Contents/Resources/ru.lproj/"',
            prepare,
        )
        self.assertIn("CFBundleDevelopmentRegion", verifier)
        self.assertIn(
            '[[ "$ACTUAL_MANAGER_DEVELOPMENT_REGION" != "ru" ]]',
            verifier,
        )
        self.assertIn('cmp -s "$expected" "$packaged"', verifier)

    def test_enrollment_helper_is_exact_private_and_bounded(self) -> None:
        text = ENROLL.read_text(encoding="utf-8")

        self.assertIn('stat -f \'%u\' /dev/console', text)
        self.assertIn('launchctl print "gui/$EUID"', text)
        self.assertIn("Authority=Developer ID Application:", text)
        self.assertIn("Timestamp=", text)
        self.assertIn("/usr/bin/open -n -W -a \"$APP_PATH\"", text)
        self.assertIn("--stderr \"$LOG_PATH\"", text)
        self.assertIn("--args", text)
        self.assertIn("--neantik-enroll-fingerprint-evidence", text)
        self.assertIn("--output \"$OUTPUT_PATH\"", text)
        self.assertNotIn("cat \"$LOG_PATH\"", text)
        self.assertNotIn("run-exact-command-with-timeout.py", text)

    def test_release_only_verifies_and_notarizes_prepared_candidate(self) -> None:
        text = RELEASE.read_text(encoding="utf-8")
        self.assertIn("NEXT_PUBLIC_NEANTIK_DOWNLOAD_URL:?", text)
        self.assertIn("NEANTIK_RELEASE_CHANNEL", text)
        self.assertIn("direct-candidate-manifest.py", text)
        self.assertEqual(text.count("direct-candidate-manifest.py"), 1)
        self.assertIn("run-isolated-release-python.py", text)
        self.assertEqual(
            text.count("run-isolated-release-python.py"),
            5,  # Existing four gates plus registered location validation.
        )
        self.assertIn("verify-browser-identity-issuance.py", text)
        self.assertIn("notary_transaction_inspector.py", text)
        self.assertIn("--release-gate", text)
        self.assertIn("--expected-archive-name", text)
        self.assertIn("EXPECTED_ARCHIVE=", text)
        self.assertIn("notarize-direct-candidate.sh", text)
        self.assertNotIn("verify-direct-notarized-archive.py", text)
        self.assertIn(
            "verify-direct-notarized-archive.py",
            NOTARY_TRANSACTION.read_text(encoding="utf-8"),
        )
        self.assertNotIn("sign-runtime.sh", text)
        self.assertNotIn("package-integrated-app.sh", text)
        self.assertNotIn("codesign --force", text)
        self.assertNotIn("rm -rf", text)
        self.assertLess(
            text.index("verify-browser-identity-issuance.py"),
            text.index("direct-candidate-manifest.py"),
        )
        self.assertLess(
            text.index("direct-candidate-manifest.py"),
            text.index("notary_transaction_inspector.py"),
        )
        self.assertLess(
            text.index("notary_transaction_inspector.py"),
            text.index("notarize-direct-candidate.sh"),
        )

    def test_notarization_requires_authenticated_schema8_evidence(self) -> None:
        wrapper = NOTARIZE.read_text(encoding="utf-8")
        text = NOTARY_TRANSACTION.read_text(encoding="utf-8")
        fresh = text.split("def run_transaction(", 1)[1]

        self.assertIn("verify-fingerprint-evidence-envelope.py", text)
        self.assertIn("snapshot_candidate_inputs", text)
        self.assertIn("--integrated-app", text)
        self.assertIn("observe_sealed_phase", text)
        self.assertIn('"notarytool",\n                    "submit"', text)
        self.assertIn('"notarytool",\n                "info"', text)
        self.assertIn('"stapler", "staple", str(staged_app)', text)
        self.assertIn("publish_or_adopt_sealed_file", text)
        self.assertIn('"submit-intent"', text)
        self.assertIn('"submission-known"', text)
        self.assertIn('"sidecar-committed"', text)
        self.assertIn('"zip-committed"', text)
        self.assertIn('"publication-complete"', text)
        self.assertIn("release_source_receipt", text)
        self.assertIn('"--no-wait"', text)
        self.assertIn('"notarytool",\n                    "wait"', text)
        self.assertIn('"publicationState": "transaction-verified"', text)
        self.assertIn("refusing overwrite", text)
        self.assertIn("Authority=Developer ID Application:", text)
        self.assertIn("Timestamp=", text)
        self.assertIn("verify-runtime-security-baseline.py", text)
        self.assertIn("--allow-public-alpha-tuples", text)
        self.assertIn("verify-runtime-security-reference.py", text)
        self.assertIn("verify-direct-update-policy.py", text)
        self.assertIn("verify-public-fingerprint-corpus.py", text)
        self.assertNotIn("verify-gui-fingerprint-report.py", text)
        self.assertNotIn("rm -f", wrapper)
        self.assertNotIn("notarytool submit", wrapper)
        self.assertNotIn("stapler", wrapper)
        self.assertIn("notarize_direct_transaction.py", wrapper)
        self.assertIn("--source-binding", wrapper)
        self.assertIn("direct-candidate-source.json", wrapper)
        self.assertIn("run-isolated-release-python.py", wrapper)
        self.assertIn("git -C \"$PROJECT_DIR\" ls-files -z -- '*.py'", wrapper)
        self.assertIn('python_cache="$python_parent/__pycache__"', wrapper)
        self.assertIn('find "$python_cache" -depth -delete', wrapper)
        self.assertNotIn('find "$PROJECT_DIR/scripts"', wrapper)
        self.assertIn("/opt/homebrew/bin/python3", wrapper)
        self.assertIn("Python 3.11", wrapper)
        self.assertLess(
            fresh.index("submission ZIP packaging"),
            fresh.index('"notarytool",\n                    "submit"'),
        )
        self.assertLess(
            fresh.index('"notarytool",\n                    "submit"'),
            fresh.index('"stapler", "staple", str(staged_app)'),
        )
        self.assertLess(
            fresh.index('"stapler", "staple", str(staged_app)'),
            fresh.index("final ZIP packaging"),
        )
        self.assertLess(
            fresh.index("final notarized archive verification"),
            fresh.index("publish_or_adopt_sealed_file"),
        )


if __name__ == "__main__":
    unittest.main()
