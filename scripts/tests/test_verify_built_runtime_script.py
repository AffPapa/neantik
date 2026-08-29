import unittest
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = PROJECT_ROOT / "scripts" / "verify-built-runtime.sh"


class VerifyBuiltRuntimeScriptTests(unittest.TestCase):
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
