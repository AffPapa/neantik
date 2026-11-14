import importlib
import json
from pathlib import Path
import signal
import sys
import tempfile
import unittest
from unittest.mock import patch

RUNTIME = Path(__file__).resolve().parents[1] / "runtime-network"
sys.path.insert(0, str(RUNTIME))
RESTART = importlib.import_module("restart-owned-webkit-networking")


class OwnedNetworkingRestartTests(unittest.TestCase):
    def setUp(self):
        def temporary(prefix):
            resource = tempfile.TemporaryDirectory(prefix=prefix, dir="/private/tmp")
            self.addCleanup(resource.cleanup)
            return Path(resource.name)

        self.root = temporary("neantik-dev-fixture.")
        self.plan = temporary("neantik-webkit-ab-stage-") / "run-plan.json"
        app = temporary("neantik-owned-webkit-successor-qa-") / "NeAntik.app"
        app.mkdir()
        archive = "a" * 64
        manager = "b" * 64
        self.owner = {"pid": 123456, "generation": "test-generation",
                      "startSeconds": 1000, "startMicroseconds": 200}
        self.write(self.plan, {"root": str(self.root), "stage": str(self.plan.parent)})
        receipt = app.parent / "stage.json"
        self.write(receipt, {"root": str(self.root), "app": str(app), "sha256": archive,
                             "releaseQualified": False, "managerSignedSHA256": manager})
        self.write(self.root / "candidate-binding.json", {
            "candidateSHA256": archive, "candidateApp": str(app),
            "candidateReceiptSHA256": RESTART.CORE.sha(receipt.read_bytes()),
            "managerSignedSHA256": manager,
        })
        self.marker = self.root / f"qa-{archive[:12]}-single-start-consumed"
        self.marker.touch(mode=0o600)
        self.write(self.root / "phase-results.json", {
            "candidateSHA256": archive,
            "phases": [{"phase": name, "classification": "pass",
                        "turnBoundary": "PASS", "networkingOwner": self.owner}
                       for name in ("A1", "B1", "B2")],
        })

    @staticmethod
    def write(path, data):
        path.write_text(json.dumps(data))
        path.chmod(0o600)

    def test_generation_change_after_intent_never_signals(self):
        changed = dict(self.owner, startMicroseconds=201)
        with patch.object(RESTART.subprocess, "run", return_value=type("Result", (), {"returncode": 0})()),              patch.object(RESTART.QA, "attested_networking_owner", side_effect=[self.owner, changed]),              patch.object(RESTART.os, "kill") as kill:
            with self.assertRaisesRegex(ValueError, "final-custody-changed"):
                RESTART.restart(self.plan)
        kill.assert_not_called()

    def test_signal_is_one_use_and_exit_is_recorded(self):
        with patch.object(RESTART.subprocess, "run", return_value=type("Result", (), {"returncode": 0})()),              patch.object(RESTART.QA, "attested_networking_owner", return_value=self.owner),              patch.object(RESTART.CRASH, "generation_absent", return_value=True),              patch.object(RESTART.os, "kill") as kill:
            self.assertTrue(RESTART.restart(self.plan)["previousGenerationExited"])
            with self.assertRaisesRegex(ValueError, "already-attempted"):
                RESTART.restart(self.plan)
        kill.assert_called_once_with(self.owner["pid"], signal.SIGKILL)
