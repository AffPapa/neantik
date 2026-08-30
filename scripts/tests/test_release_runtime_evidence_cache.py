import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
RELEASE_COMMAND = ROOT / "scripts" / "Run-NeAntik-Release.command"


class ReleaseRuntimeEvidenceCacheTests(unittest.TestCase):
    def evaluate_gui_attempt(
        self,
        *,
        timed_out: bool,
        gui_exit_status: int,
        evidence: str | None,
    ) -> tuple[int, list[str]]:
        text = RELEASE_COMMAND.read_text(encoding="utf-8")
        functions_start = text.index(
            "verify_current_gui_attempt_evidence() {"
        )
        functions_end = text.index("\nattempt=1", functions_start)
        functions = text[functions_start:functions_end]

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            scripts = root / "scripts"
            scripts.mkdir()
            collector = scripts / "collect-gui-fingerprint-evidence.py"
            collector.write_text(
                """\
import os
from pathlib import Path
import sys

arguments = sys.argv[1:]
Path(os.environ["ARG_LOG"]).write_text("\\n".join(arguments), encoding="utf-8")
source = Path(arguments[arguments.index("--source") + 1])
raise SystemExit(0 if source.is_file() and source.read_text(encoding="utf-8") == "valid" else 1)
""",
                encoding="utf-8",
            )
            evidence_path = root / "attempt-1" / "fingerprint-evidence-schema8.json"
            evidence_path.parent.mkdir()
            if evidence is not None:
                evidence_path.write_text(evidence, encoding="utf-8")
            argument_log = root / "collector-arguments.txt"
            quote = shlex.quote

            script = f"""\
set +e
PROJECT_DIR={quote(str(root))}
SCHEMA8_SOURCE={quote(str(evidence_path))}
APP_PATH={quote(str(root / 'NeAntik.app'))}
CANDIDATE_MANIFEST={quote(str(root / 'direct-candidate-manifest.json'))}
NEANTIK_RELEASE_CHANNEL=public-alpha
GUI_NOT_BEFORE=2026-08-29T16:50:43Z
REPORT_PATH={quote(str(root / 'fingerprint-audit.json'))}
GUI_TIMED_OUT={1 if timed_out else 0}
GUI_EXIT_STATUS={gui_exit_status}
{functions}
evaluate_current_gui_attempt
exit $?
"""
            environment = os.environ.copy()
            environment["ARG_LOG"] = str(argument_log)
            completed = subprocess.run(
                ["/bin/zsh", "-c", script],
                capture_output=True,
                text=True,
                check=False,
                env=environment,
            )
            arguments = (
                argument_log.read_text(encoding="utf-8").splitlines()
                if argument_log.exists()
                else []
            )
            return completed.returncode, arguments

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
        evaluator = text.index(
            "evaluate_current_gui_attempt ||",
            wait,
        )
        notarization = text.index(
            "[3/4] Отправляю кандидат в Apple notarization…"
        )
        self.assertLess(first_drain, launch)
        self.assertLess(wait, second_drain)
        self.assertLess(second_drain, evaluator)
        self.assertLess(evaluator, final_drain)
        self.assertLess(final_drain, notarization)
        self.assertNotIn("pkill", text)
        self.assertNotIn("kill -9", text)

    def test_timeout_accepts_only_valid_evidence_from_the_same_attempt(self) -> None:
        status, arguments = self.evaluate_gui_attempt(
            timed_out=True,
            gui_exit_status=143,
            evidence="valid",
        )

        self.assertEqual(status, 0)
        self.assertIn("--source", arguments)
        source = arguments[arguments.index("--source") + 1]
        self.assertTrue(source.endswith("attempt-1/fingerprint-evidence-schema8.json"))
        self.assertEqual(
            arguments[arguments.index("--not-before") + 1],
            "2026-08-29T16:50:43Z",
        )
        self.assertIn("--integrated-app", arguments)
        self.assertIn("--candidate-manifest", arguments)
        self.assertEqual(
            arguments[arguments.index("--release-channel") + 1],
            "public-alpha",
        )

    def test_timeout_with_invalid_evidence_stays_fail_closed(self) -> None:
        status, _ = self.evaluate_gui_attempt(
            timed_out=True,
            gui_exit_status=143,
            evidence="invalid",
        )

        self.assertEqual(status, 67)

    def test_timeout_with_missing_evidence_stays_fail_closed(self) -> None:
        status, _ = self.evaluate_gui_attempt(
            timed_out=True,
            gui_exit_status=143,
            evidence=None,
        )

        self.assertEqual(status, 67)

    def test_timeout_success_still_requires_exact_source_binding(self) -> None:
        text = RELEASE_COMMAND.read_text(encoding="utf-8")
        evaluator = text.index("evaluate_current_gui_attempt ||")
        binding = text.rindex(
            'python3 "$PROJECT_DIR/scripts/direct-candidate-source-binding.py" verify'
        )
        notarization = text.index(
            "[3/4] Отправляю кандидат в Apple notarization…"
        )

        self.assertLess(evaluator, binding)
        self.assertLess(binding, notarization)

    def test_non_timeout_nonzero_exit_does_not_accept_evidence(self) -> None:
        status, arguments = self.evaluate_gui_attempt(
            timed_out=False,
            gui_exit_status=70,
            evidence="valid",
        )

        self.assertEqual(status, 66)
        self.assertEqual(arguments, [])


if __name__ == "__main__":
    unittest.main()
