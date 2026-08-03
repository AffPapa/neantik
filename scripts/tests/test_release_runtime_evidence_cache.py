from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
RELEASE_COMMAND = ROOT / "scripts" / "Run-NeAntik-Release.command"


class ReleaseRuntimeEvidenceCacheTests(unittest.TestCase):
    def test_release_caches_verified_runtime_evidence_before_moving_candidate(self) -> None:
        text = RELEASE_COMMAND.read_text(encoding="utf-8")

        cache_call = text.index("cache_runtime_source_evidence\n")
        candidate_move = text.index('mv "$APP_PATH" "$ATTEMPT_STATE_ROOT/previous-NeAntik.app"')

        self.assertLess(cache_call, candidate_move)
        self.assertIn("verify-runtime-source-provenance.py", text)
        self.assertIn("verify-runtime-candidate-lock.py", text)
        self.assertIn('chmod 0600 \\\n', text)
        self.assertIn(
            'export NEANTIK_SOURCE_PROVENANCE="$cached_dir/source-provenance.json"',
            text,
        )
        self.assertIn(
            'export NEANTIK_RUNTIME_CANDIDATE_LOCK="$cached_dir/runtime-candidate-lock.json"',
            text,
        )

    def test_release_can_recover_evidence_from_previous_private_attempts(self) -> None:
        text = RELEASE_COMMAND.read_text(encoding="utf-8")

        self.assertIn(
            '"$PROJECT_DIR/artifacts/neantik/private-release-attempts"',
            text,
        )
        self.assertIn("-type f -name source-provenance.json", text)
        self.assertIn('lock="$evidence_dir/fingerprint-chromium.lock.json"', text)


if __name__ == "__main__":
    unittest.main()
