import contextlib
import io
import json
import sys
import unittest
from pathlib import Path
from unittest import mock


sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import notarize_direct_transaction as MODULE


class DirectStageTimingTests(unittest.TestCase):
    def invoke(self, runner, *, label="integrated release verification"):
        output = io.StringIO()
        with contextlib.redirect_stderr(output), mock.patch.object(
            MODULE.time, "monotonic_ns", side_effect=[5_000_000_000, 6_250_000_000]
        ):
            value = MODULE.run_checked(
                ["private-command", "private-argument"],
                cwd=Path("/private/fixture"),
                runner=runner,
                label=label,
            )
        return value, [json.loads(line) for line in output.getvalue().splitlines()]

    def test_elapsed_is_monotonic_and_result_output_is_unchanged(self):
        runner = mock.Mock(return_value=MODULE.CommandResult(0, "child output", "private stderr"))
        value, records = self.invoke(runner)
        runner.assert_called_once()
        self.assertEqual(value, "child output")
        self.assertEqual(records, [
            {"kind": "neantik.direct-stage", "stage": "integrated release verification", "event": "start"},
            {"kind": "neantik.direct-stage", "stage": "integrated release verification", "event": "end", "elapsedSeconds": 1.25, "outcome": "exit-zero"},
        ])
        self.assertNotIn("private", json.dumps(records))
        self.assertNotIn("child output", json.dumps(records))

    def test_unreviewed_label_cannot_enter_diagnostics(self):
        _, records = self.invoke(
            lambda *_: MODULE.CommandResult(0, ""),
            label="private user path or token",
        )
        self.assertEqual({record["stage"] for record in records}, {"unclassified"})
        self.assertNotIn("private", json.dumps(records))

    def test_refused_and_timeout_commands_still_fail(self):
        for code in (1, 75, 124):
            with self.subTest(code=code):
                output = io.StringIO()
                with contextlib.redirect_stderr(output), self.assertRaisesRegex(
                    MODULE.DirectNotaryTransactionError, "integrated release verification failed"
                ):
                    MODULE.run_checked(
                        ["not-printed"], cwd=Path.cwd(),
                        runner=lambda *_: MODULE.CommandResult(code, "private child diagnostic"),
                        label="integrated release verification",
                    )
                records = [json.loads(line) for line in output.getvalue().splitlines()]
                self.assertEqual(records[-1]["outcome"], "exit-nonzero")
                self.assertNotIn("private child diagnostic", output.getvalue())

    def test_runner_exception_identity_is_preserved(self):
        error = OSError("private child exception")
        output = io.StringIO()
        with contextlib.redirect_stderr(output), self.assertRaises(OSError) as raised:
            MODULE.run_checked(
                ["not-printed"], cwd=Path.cwd(), runner=mock.Mock(side_effect=error),
                label="submission ZIP packaging",
            )
        self.assertIs(raised.exception, error)
        records = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertEqual(records[-1]["outcome"], "runner-error")
        self.assertNotIn("private child exception", output.getvalue())

    def test_closed_log_neither_skips_nor_passes_a_gate(self):
        for result in (MODULE.CommandResult(0, "unchanged"), MODULE.CommandResult(1, "refused")):
            runner = mock.Mock(return_value=result)
            with mock.patch("builtins.print", side_effect=BrokenPipeError):
                if result.returncode:
                    with self.assertRaises(MODULE.DirectNotaryTransactionError):
                        MODULE.run_checked(["fixture"], cwd=Path.cwd(), runner=runner, label="Gatekeeper assessment")
                else:
                    self.assertEqual(MODULE.run_checked(["fixture"], cwd=Path.cwd(), runner=runner, label="Gatekeeper assessment"), "unchanged")
            runner.assert_called_once()

    def test_each_copy_still_executes_its_gate(self):
        runner = mock.Mock(return_value=MODULE.CommandResult(0, "unchanged"))
        output = io.StringIO()
        with contextlib.redirect_stderr(output):
            for copy in ("precheck", "accepted", "stapled", "extracted"):
                MODULE.run_checked(
                    ["fixture", copy], cwd=Path.cwd(), runner=runner,
                    label="integrated release verification",
                )
        self.assertEqual(runner.call_count, 4)
        self.assertEqual(len(output.getvalue().splitlines()), 8)

    def test_real_child_output_remains_separate_from_timing(self):
        output = io.StringIO()
        with contextlib.redirect_stderr(output):
            result = MODULE.run_checked(
                [sys.executable, "-c", "import sys; print('own-child-result'); print('own-child-stderr', file=sys.stderr)"],
                cwd=Path.cwd(), runner=MODULE.default_runner,
                label="candidate manifest verification", include_stderr=True,
            )
        self.assertEqual(result, "own-child-result\nown-child-stderr")
        records = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertEqual(records[-1]["outcome"], "exit-zero")
        self.assertGreaterEqual(records[-1]["elapsedSeconds"], 0)
        self.assertNotIn("own-child", output.getvalue())


if __name__ == "__main__":
    unittest.main()
