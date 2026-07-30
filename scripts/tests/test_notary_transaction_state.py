import importlib.util
import json
import os
import stat
import sys
import tempfile
import unittest
import uuid
from pathlib import Path


SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
SCRIPT = SCRIPTS / "notary_transaction_state.py"
SPEC = importlib.util.spec_from_file_location(
    "notary_transaction_state",
    SCRIPT,
)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class NotaryTransactionStateTests(unittest.TestCase):
    def test_state_chain_is_append_only_canonical_and_hash_linked(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "transaction"
            transaction_id = str(uuid.uuid4())
            store = MODULE.StateStore(root, transaction_id)
            first = store.commit(
                "transaction-created",
                {"archiveName": "NeAntik-1.2.3.zip"},
            )
            second = store.commit(
                "submission-ready",
                {"sha256": "a" * 64},
            )

            self.assertEqual(
                second.payload["previousReceiptSHA256"],
                first.sha256,
            )
            self.assertEqual(
                stat.S_IMODE(first.path.stat().st_mode),
                0o400,
            )
            self.assertEqual(len(store.load()), 2)
            self.assertEqual(
                first.path.read_bytes(),
                MODULE.canonical_json_bytes(first.payload),
            )

    def test_gap_unknown_file_and_tamper_fail_closed(self) -> None:
        for mutation in ("gap", "unknown", "tamper"):
            with self.subTest(mutation=mutation):
                with tempfile.TemporaryDirectory() as temporary:
                    root = Path(temporary) / "transaction"
                    store = MODULE.StateStore(root, str(uuid.uuid4()))
                    receipt = store.commit(
                        "transaction-created",
                        {"archiveName": "NeAntik-1.2.3.zip"},
                    )
                    if mutation == "gap":
                        receipt.path.rename(
                            store.state
                            / (
                                "10-submission-ready."
                                + receipt.sha256
                                + ".json"
                            )
                        )
                    elif mutation == "unknown":
                        (store.state / "unexpected.json").write_text(
                            "{}\n",
                            encoding="utf-8",
                        )
                    else:
                        receipt.path.chmod(0o600)
                        payload = json.loads(
                            receipt.path.read_text(encoding="utf-8")
                        )
                        payload["data"]["archiveName"] = "changed.zip"
                        receipt.path.write_bytes(
                            MODULE.canonical_json_bytes(payload)
                        )
                        receipt.path.chmod(0o400)
                    with self.assertRaises(
                        MODULE.NotaryTransactionStateError
                    ):
                        store.load()

    def test_invalid_transition_and_duplicate_commit_fail_closed(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            store = MODULE.StateStore(
                Path(temporary) / "transaction",
                str(uuid.uuid4()),
            )
            with self.assertRaisesRegex(
                MODULE.NotaryTransactionStateError,
                "transition",
            ):
                store.commit("submission-ready", {})
            store.commit("transaction-created", {})
            with self.assertRaisesRegex(
                MODULE.NotaryTransactionStateError,
                "transition",
            ):
                store.commit("transaction-created", {})

    def test_non_finite_state_value_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            store = MODULE.StateStore(
                Path(temporary) / "transaction",
                str(uuid.uuid4()),
            )
            with self.assertRaisesRegex(
                MODULE.NotaryTransactionStateError,
                "canonical JSON",
            ):
                store.commit(
                    "transaction-created",
                    {"value": float("nan")},
                )
            self.assertEqual(store.load(), ())

    def test_lock_rejects_concurrent_owner_process(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary) / "locks"
            first = MODULE.acquire_transaction_lock(
                directory,
                "NeAntik-1.2.3.zip",
            )
            try:
                with self.assertRaisesRegex(
                    MODULE.NotaryTransactionStateError,
                    "active",
                ):
                    MODULE.acquire_transaction_lock(
                        directory,
                        "NeAntik-1.2.3.zip",
                    )
            finally:
                os.close(first)

    def test_unfinished_submit_intent_is_discovered_before_resubmit(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            dist = Path(temporary)
            transaction = dist / ".neantik-notary.fixture"
            transaction_id = str(uuid.uuid4())
            store = MODULE.StateStore(transaction, transaction_id)
            store.commit(
                "transaction-created",
                {"archiveName": "NeAntik-1.2.3.zip"},
            )
            store.commit("submission-ready", {"sha256": "a" * 64})
            store.commit("submit-intent", {"sha256": "a" * 64})

            active = MODULE.find_active_transaction(
                dist,
                "NeAntik-1.2.3.zip",
            )
            self.assertIsNotNone(active)
            assert active is not None
            self.assertEqual(active[0], transaction)
            self.assertEqual(active[1][-1].stage, "submit-intent")


if __name__ == "__main__":
    unittest.main()
