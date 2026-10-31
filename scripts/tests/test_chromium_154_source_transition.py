import copy
import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from chromium_154_source_transition import TransitionError, verify_transition


def entry(path="input.cc", digest="a" * 64):
    return {"path": path, "kind": "file", "mode": 0o644, "sizeBytes": 10, "sha256": digest}


def snapshot(entries):
    return {"schemaVersion": 1, "entries": entries, "deletedPaths": [],
            "sourceFileCount": len(entries), "deletedPathCount": 0,
            "argsGN": {"sha256": "d" * 64}, "targetChromiumVersion": "154.0.8037.93",
            "officialChromiumBase": {"commit": "pinned"}}


class TransitionTests(unittest.TestCase):
    def setUp(self):
        self.before = snapshot([entry()])
        self.after = snapshot([entry(digest="c" * 64)])
        self.steps = [{"path": "input.cc", "beforeSHA256": pre * 64,
                       "afterSHA256": post * 64, "patchSHA256": "f" * 64}
                      for pre, post in [("a", "b"), ("b", "c")]]

    def test_ordered_chain_binds_both_inventories(self):
        report = verify_transition(self.before, self.after, self.steps)
        self.assertEqual(len(report["changes"]), 1)
        self.assertNotEqual(report["beforeSnapshot"]["entriesSHA256"], report["afterSnapshot"]["entriesSHA256"])
        self.assertFalse(report["releaseReady"])

    def test_wrong_order_and_missing_step_fail(self):
        for steps in (list(reversed(self.steps)), self.steps[:1], self.steps[1:], []):
            with self.assertRaises(TransitionError):
                verify_transition(self.before, self.after, steps)

    def test_unexplained_change_addition_deletion_and_mode_fail(self):
        cases = [snapshot([]), snapshot([entry(), entry("other.cc")]),
                 snapshot([dict(entry(digest="c" * 64), mode=0o755)]),
                 snapshot([dict(entry(digest="c" * 64), kind="symlink")])]
        for after in cases:
            with self.assertRaises(TransitionError):
                verify_transition(self.before, after, self.steps)

    def test_metadata_and_duplicate_paths_fail(self):
        changed = copy.deepcopy(self.after)
        changed["argsGN"] = {"sha256": "e" * 64}
        for after in (changed, snapshot([entry(), entry()]), dict(self.after, releaseReady=True)):
            with self.assertRaises(TransitionError):
                verify_transition(self.before, after, self.steps)

    def test_generator_inputs_produce_serializable_evidence(self):
        report = verify_transition(self.before, self.after, iter(self.steps), iter([]))
        self.assertEqual(json.loads(json.dumps(report))["overlaySteps"], self.steps)

    def test_symlink_target_change_fails(self):
        link = {"path": "link", "kind": "symlink", "mode": 0o755,
                "targetLength": 1, "targetSHA256": "a" * 64}
        with self.assertRaises(TransitionError):
            verify_transition(snapshot([link]), snapshot([dict(link, targetSHA256="b" * 64)]), [])

    def test_cache_requires_exact_source_and_review(self):
        before = snapshot([entry("mod.py")])
        after = snapshot(sorted([entry("mod.py"), entry("pkg/__pycache__/mod.cpython-311.pyc", "b" * 64)], key=lambda x:x["path"]))
        cache = {"path": "pkg/__pycache__/mod.cpython-311.pyc", "sourcePath": "mod.py",
                 "sourceSHA256": "a" * 64, "pycSHA256": "b" * 64, "timestampAndCodeMatch": True}
        self.assertEqual(len(verify_transition(before, after, [], [cache])["changes"]), 1)
        self.assertEqual(len(verify_transition(before, after, [], iter([cache]))["verifiedCaches"]), 1)
        with self.assertRaises(TransitionError):
            verify_transition(before, after, [], [cache, cache])
        for bad in (dict(cache, timestampAndCodeMatch=False), dict(cache, sourceSHA256="c" * 64), dict(cache, path="../bad.pyc")):
            with self.assertRaises(TransitionError):
                verify_transition(before, after, [], [bad])


if __name__ == "__main__":
    unittest.main()
