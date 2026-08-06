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

    def test_release_reuses_only_candidate_from_exact_current_source(self) -> None:
        text = RELEASE_COMMAND.read_text(encoding="utf-8")

        self.assertIn(
            'CANDIDATE_SOURCE_BINDING="$PROJECT_DIR/dist/direct-candidate-source.json"',
            text,
        )
        self.assertIn("direct-candidate-source-binding.py", text)
        self.assertIn("--project-root \"$PROJECT_DIR\"", text)
        self.assertIn("--binding \"$CANDIDATE_SOURCE_BINDING\"", text)
        self.assertIn(
            'mv "$CANDIDATE_SOURCE_BINDING" '
            '"$ATTEMPT_STATE_ROOT/previous-direct-candidate-source.json"',
            text,
        )
        source_verifications = [
            index
            for index in range(len(text))
            if text.startswith(
                'python3 "$PROJECT_DIR/scripts/direct-candidate-source-binding.py" verify',
                index,
            )
        ]
        self.assertEqual(len(source_verifications), 2)
        self.assertLess(
            source_verifications[-1],
            text.index("[3/4] Отправляю кандидат в Apple notarization…"),
        )

    def test_release_waits_before_retrying_gui_audit(self) -> None:
        text = RELEASE_COMMAND.read_text(encoding="utf-8")

        retry_message = (
            "Отчёт ещё не создан. Жду полного завершения Chromium "
            "и безопасно повторяю проверку."
        )
        retry_index = text.index(retry_message)
        sleep_index = text.index("sleep 3", retry_index)
        increment_index = text.index("(( attempt += 1 ))", sleep_index)

        self.assertLess(retry_index, sleep_index)
        self.assertLess(sleep_index, increment_index)
        first_drain = text.index("wait-for-neantik-runtime-drain.py")
        launch = text.index('"$APP_PATH/Contents/MacOS/NeAntik"')
        wait = text.index('wait "$GUI_PID"', launch)
        second_drain = text.index(
            "wait-for-neantik-runtime-drain.py",
            first_drain + 1,
        )
        final_drain = text.index(
            "wait-for-neantik-runtime-drain.py",
            second_drain + 1,
        )
        collector = text.index(
            "collect-gui-fingerprint-evidence.py",
            wait,
        )
        notarization = text.index(
            "[3/4] Отправляю кандидат в Apple notarization…"
        )
        self.assertLess(first_drain, launch)
        self.assertLess(wait, second_drain)
        self.assertLess(second_drain, collector)
        self.assertLess(collector, final_drain)
        self.assertLess(final_drain, notarization)
        self.assertNotIn("pkill", text)
        self.assertNotIn("kill -9", text)


if __name__ == "__main__":
    unittest.main()
