import json
import subprocess
import tempfile
import unittest
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = PROJECT_ROOT / "scripts" / "verify-built-runtime.sh"


class VerifyBuiltRuntimeScriptTests(unittest.TestCase):
    def test_unsupported_chromium_version_never_falls_back_to_152(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = root / "NeAntik Browser.app"
            app.mkdir()
            candidate_lock = root / "candidate-lock.json"
            candidate_lock.write_text(
                json.dumps(
                    {"fingerprintChromium": {"chromiumVersion": "155.0.9000.1"}}
                ),
                encoding="utf-8",
            )
            result = subprocess.run(
                [
                    "bash",
                    str(SCRIPT),
                    str(app),
                    "",
                    "",
                    "",
                    str(candidate_lock),
                ],
                capture_output=True,
                text=True,
                check=False,
            )

        self.assertEqual(result.returncode, 65)
        self.assertIn("Unsupported Chromium runtime version", result.stderr)

    def test_supported_m154_version_uses_owned_candidate_provenance(self) -> None:
        script = SCRIPT.read_text(encoding="utf-8")

        self.assertIn('[[ "$LOCK_VERSION" == 153.* ]]', script)
        self.assertIn('[[ "$LOCK_VERSION" == 152.* ]]', script)
        self.assertIn('[[ "$LOCK_VERSION" == "154.0.8037.93" ]]', script)
        self.assertIn('[[ "$LOCK_VERSION" == "154.0.8037.98" ]]', script)
        self.assertIn(
            'SOURCE_CONTRACT_FILE="$SCRIPT_DIR/../runtime/chromium-154-source-contract.json"',
            script,
        )
        self.assertIn(
            '[[ "$LOCK_VERSION" == "154.0.8037.58" && -n "$REPORT_PATH" ]]',
            script,
        )
        self.assertIn("IS_CHROMIUM_154 == 1", script)
        self.assertIn("IS_CHROMIUM_15498 == 1", script)
        self.assertIn("verify-chromium-154-source-snapshot.py", script)
        self.assertIn("M154_SOURCE_SNAPSHOT_VERIFIED=1", script)
        self.assertIn(
            "Chromium source snapshot verification is required.", script
        )

    def test_m154_cannot_skip_live_source_snapshot_verification(self) -> None:
        script = SCRIPT.read_text(encoding="utf-8")
        branch_start = script.index("elif (( IS_CHROMIUM_154 == 1 || IS_CHROMIUM_15498 == 1", script.index("SOURCE_POSTIMAGES_VERIFIED=0"))
        branch_end = script.index("elif [[ -f \"$SOURCE_ROOT/components/ungoogled/BUILD.gn\" ]]", branch_start)
        branch = script[branch_start:branch_end]

        self.assertIn("M154_SOURCE_SNAPSHOT_VERIFIED != 1", branch)
        self.assertNotIn("M154_SOURCE_SNAPSHOT_VERIFIED=1", branch)

    def test_new_report_requires_source_provenance_schema_three(self) -> None:
        script = SCRIPT.read_text(encoding="utf-8")

        self.assertIn('"schemaVersion": 3', script)
        self.assertIn("sourceContractSHA256", script)
        self.assertIn("sourceProvenanceSHA256", script)
        self.assertIn(
            "A new runtime report requires owned Chromium source provenance.",
            script,
        )

    def test_generated_postimages_override_patch_group_intermediates(self) -> None:
        script = SCRIPT.read_text(encoding="utf-8")

        self.assertIn("generated_postimages = {}", script)
        self.assertIn(
            "expected_postimages.update(generated_postimages)",
            script,
        )
        self.assertLess(
            script.index("generated_postimages = {}"),
            script.index(
                "expected_postimages.update(generated_postimages)"
            ),
        )
        self.assertIn(
            "Canonical generated runtime postimages are missing.",
            script,
        )
        self.assertIn(
            "A new runtime report requires verified canonical source "
            "postimages.",
            script,
        )

    def test_canonical_tuple_binding_rejects_provisional_salt_marker(self) -> None:
        script = SCRIPT.read_text(encoding="utf-8")

        required_block = script[
            script.index("required = {"):script.index("forbidden = {")
        ]
        forbidden_block = script[
            script.index("forbidden = {"):script.index("found_forbidden")
        ]
        self.assertNotIn('"apple-device-tuple"', required_block)
        self.assertIn('"apple-device-tuple"', forbidden_block)
        self.assertIn(
            "Forbidden legacy or provisional fingerprint marker",
            script,
        )

    def test_report_contains_no_local_absolute_paths(self) -> None:
        script = SCRIPT.read_text(encoding="utf-8")

        self.assertIn(
            '"path": os.environ["EXECUTABLE_BUNDLE_PATH"]',
            script,
        )
        self.assertIn(
            '"path": os.environ["FRAMEWORK_BUNDLE_PATH"]',
            script,
        )
        self.assertNotIn(
            '"path": os.environ["EXECUTABLE_PATH"]',
            script,
        )
        self.assertNotIn(
            '"path": os.environ["FRAMEWORK_PATH"]',
            script,
        )
        self.assertNotIn(
            '"path": os.environ["BUILD_ARGS_PATH"]',
            script,
        )

    def test_report_requires_and_binds_explicit_candidate_lock(self) -> None:
        script = SCRIPT.read_text(encoding="utf-8")

        self.assertIn("CANDIDATE_LOCK_PATH", script)
        self.assertIn(
            "A new runtime report requires an explicit schema 4 candidate lock.",
            script,
        )
        self.assertIn(
            '"candidateLockSHA256": os.environ["CANDIDATE_LOCK_SHA256"]',
            script,
        )
        self.assertIn("verify-runtime-candidate-lock.py", script)

    def test_build_exports_candidate_after_provenance_before_binary_build(self) -> None:
        build = (
            PROJECT_ROOT / "scripts" / "build-runtime.sh"
        ).read_text(encoding="utf-8")

        provenance = build.index("export-runtime-source-provenance.py")
        candidate = build.index("export-runtime-candidate-lock.py")
        ninja = build.index("ninja -C out/Default")
        self.assertLess(provenance, candidate)
        self.assertLess(candidate, ninja)

    def test_protocol_markers_are_checked_in_one_streaming_pass(self) -> None:
        script = SCRIPT.read_text(encoding="utf-8")

        self.assertIn('handle.read(1024 * 1024)', script)
        self.assertIn('"NEANTIK_PROFILE_SEED"', script)
        self.assertIn('"NEANTIK_PROFILE_TIMEZONE"', script)
        self.assertIn('"WebGPUService"', script)
        self.assertIn('"fingerprint-timezone"', script)
        self.assertIn('"fingerprint-locale"', script)
        self.assertIn('"fingerprint-platform"', script)
        self.assertIn(
            "Forbidden legacy or provisional fingerprint marker",
            script,
        )
        self.assertNotIn("for protocol_string in", script)

    def test_rejects_misaligned_macho_linkedit_string_tables(self) -> None:
        script = SCRIPT.read_text(encoding="utf-8")

        self.assertIn('otool -l "$MACHO_INSPECTION_PATH"', script)
        self.assertIn('ln -s "$binary" "$MACHO_INSPECTION_PATH"', script)
        self.assertIn("otool-classic treats a parenthesized path", script)
        self.assertIn('LC_SYMTAB', script)
        self.assertIn('string_table_offset % 8 != 0', script)
        self.assertIn(
            "Misaligned 64-bit Mach-O LINKEDIT string table",
            script,
        )

    def test_public_contract_does_not_document_legacy_private_argv(self) -> None:
        contract = (
            PROJECT_ROOT / "docs" / "FINGERPRINT_RUNTIME.md"
        ).read_text(encoding="utf-8")
        manager = (
            PROJECT_ROOT / "Sources" / "NeAntik" /
            "BrowserProcessManager.swift"
        ).read_text(encoding="utf-8")

        for marker in (
            "--fingerprint=<",
            "--fingerprint-platform=",
            "--fingerprint-timezone=",
            "--fingerprint-locale=",
        ):
            self.assertNotIn(marker, contract)
        self.assertIn("NEANTIK_PROFILE_SEED=<", contract)
        self.assertIn("NEANTIK_PROFILE_TIMEZONE=<", contract)
        self.assertNotIn('arguments.append("--fingerprint=', manager)
        self.assertNotIn(
            'arguments.append("--fingerprint-timezone=',
            manager,
        )


if __name__ == "__main__":
    unittest.main()
