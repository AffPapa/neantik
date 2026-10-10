import hashlib
import json
import os
import tempfile
import unittest
from pathlib import Path

from chromium_15612_receipt_projection import (
    ProjectionError, checked_file, project_value, projection, strict_json, prepare, verify_prepared, VERSION, COMMIT, TREE,
)


class M156ReceiptProjectionTests(unittest.TestCase):
    def setUp(self):
        self.roots = {"source": Path("/Users/alice/build/src"),
                      "workspace": Path("/Users/alice/build"),
                      "developer": Path("/Applications/OwnedXcode.app/Contents/Developer")}

    def test_projection_keeps_every_record_and_original_digest(self):
        payload = {"records": [{"path": "/Users/alice/build/src/base/a.cc", "sha256": "a" * 64},
                               {"path": "/Users/alice/build/archive.tgz", "count": 2}],
                   "compiler": "/Applications/OwnedXcode.app/Contents/Developer/clang",
                   "releaseReady": False}
        raw = json.dumps(payload).encode()
        document = projection(raw, "owned.json", self.roots)
        self.assertEqual(document["originalReceiptSHA256"], hashlib.sha256(raw).hexdigest())
        self.assertEqual(len(document["payload"]["records"]), 2)
        self.assertEqual(document["payload"]["records"][0], {"path": "root:source/base/a.cc", "sha256": "a" * 64})
        self.assertEqual(document["payload"]["records"][1]["path"], "root:workspace/archive.tgz")
        self.assertNotIn("/Users/", json.dumps(document))
        self.assertFalse(document["releaseReady"])

    def test_embedded_args_are_normalized_without_discarding_text(self):
        value = 'clang "'+str(self.roots["source"])+'/a.cc" --owned=2'
        self.assertEqual(project_value(value, self.roots), 'clang "root:source/a.cc" --owned=2')
        public = projection(value.encode(), "owned.txt", self.roots)
        self.assertEqual(public["payloadType"], "text")
        self.assertIn("--owned=2", public["payload"])

    def test_unknown_or_prefix_collision_path_never_disappears_silently(self):
        for value in ["/Users/example/private", "/Users/alice/buildsrc/a", "/Volumes/private/a",
                      "args=/private/tmp/unknown/x", "file:///public/a", "\\Users\\other\\a"]:
            with self.subTest(value=value), self.assertRaises(ProjectionError):
                project_value(value, self.roots)

    def test_embedded_unknown_filesystem_paths_fail_without_dropping_text(self):
        for value in ['args=/Volumes/synthetic/private', 'args=/tmp/synthetic/private',
                      'compiler "/opt/synthetic/private"', 'paths=/etc/hosts:/tmp/synthetic/data',
                      'path=C:\\synthetic\\private', 'path=//synthetic/private']:
            with self.subTest(value=value), self.assertRaises(ProjectionError):
                project_value(value, self.roots)
        reference = 'source=https://chromium.googlesource.com/chromium/src.git'
        self.assertEqual(project_value(reference, self.roots), reference)
        with self.assertRaises(ProjectionError):
            project_value('source=https://synthetic-login:synthetic-secret@example.invalid/source', self.roots)

    def test_attached_include_unc_and_source_query_credentials_are_rejected(self):
        for value in ['compiler -I/Volumes/synthetic/private', 'compiler -isystem/Volumes/synthetic/private',
                      'args=\\\\synthetic\\private', 'source=https://example.invalid/?access_token=synthetic-only',
                      'source=https://example.invalid/?X-Goog-Signature=synthetic-only',
                      'source=https://example.invalid/?password=']:
            with self.subTest(value=value), self.assertRaises(ProjectionError):
                project_value(value, {})
        for value in ['compiler -I../../third_party/libc++/src/include',
                      'source=https://example.invalid/?sha256=' + 'a' * 64]:
            self.assertEqual(project_value(value, {}), value)

    def test_private_dictionary_key_is_normalized_too(self):
        self.assertEqual(project_value({"/Users/alice/build/src/a.cc": "a" * 64}, self.roots),
                         {"root:source/a.cc": "a" * 64})

    def test_relative_libcxx_paths_do_not_become_private_roots(self):
        for value in ['-isystem../../third_party/libc++/src/include',
                      'third_party/libc++/src/src/atomic.cpp']:
            self.assertEqual(project_value(value, {}), value)
        for value in ['-isystem=/tmp/synthetic/private', 'args=//synthetic/private']:
            with self.assertRaises(ProjectionError):
                project_value(value, {})

    def test_logical_lexical_exceptions_require_original_digest(self):
        for name, value in [('m156-generated-effective-args.txt', 'label="//synthetic/private"'),
                            ('m156-acquisition-exact-gates.json', '{"url":"gs://synthetic/private"}')]:
            with self.subTest(name=name), self.assertRaisesRegex(ProjectionError, 'requires fresh semantic review'):
                projection(value.encode(), name, {})
        for value in ['label="//synthetic/private"', 'url=gs://synthetic/private',
                      'typescript-module-alias:/tools/typescript/definitions/*|../target']:
            with self.subTest(value=value), self.assertRaises(ProjectionError):
                project_value(value, {})

    def test_normalization_cannot_drop_duplicate_record_keys(self):
        with self.assertRaises(ProjectionError):
            project_value({"/Users/alice/build/src/a": 1, "root:source/a": 2}, self.roots)

    def test_credential_fields_fail_instead_of_redacting_and_passing(self):
        for key in ["password", "proxyPassword", "Authorization", "privateKey", "cookies", "accessToken"]:
            with self.subTest(key=key), self.assertRaises(ProjectionError):
                projection(json.dumps({key: "synthetic marker"}).encode(), "owned.json", self.roots)

    def test_duplicate_and_nonfinite_json_are_rejected(self):
        for value in [b'{"a":1,"a":2}', b'{"a":NaN}', b'{"a":Infinity}']:
            with self.subTest(value=value), self.assertRaises(ProjectionError):
                strict_json(value)

    def test_slash_looking_logical_tokens_require_exact_reviewed_receipt(self):
        for name in ["m156-ift-crubit-graph.json", "m156-web-package-crubit-graph.json",
                     "m156-pinned-build-types-exact-ts-action.json"]:
            with self.subTest(name=name), self.assertRaises(ProjectionError):
                projection(b'{"command":["--path_mappings","/tools/typescript/definitions/*|../owned"]}', name, self.roots)
        with self.assertRaises(ProjectionError):
            projection(b'{"path":"//unknown/private"}', "unreviewed.json", self.roots)

    def test_names_aliases_and_types_are_bounded(self):
        for name in ["../private.json", "/private.json", "owned/archive.json", "a" * 182, "binary.bin"]:
            with self.subTest(name=name), self.assertRaises(ProjectionError):
                projection(b"{}", name, self.roots)
        with self.assertRaises(ProjectionError):
            projection(b"{}", "owned.json", {"../bad": Path("/tmp")})
        with self.assertRaises(ProjectionError):
            projection(b"{}", "owned.json", {"relative": Path("relative")})
        with self.assertRaises(ProjectionError):
            projection(b"{}", "owned.json", {"first": Path("/tmp"), "second": Path("/tmp")})

    def test_reader_rejects_symlink_directory_fifo_and_traversal(self):
        with tempfile.TemporaryDirectory(prefix="neantik-projection-test-") as folder:
            root = Path(folder)
            (root / "owned.json").write_bytes(b"{}")
            self.assertEqual(checked_file(root, "owned.json"), b"{}")
            (root / "link.json").symlink_to(root / "owned.json")
            (root / "directory.json").mkdir()
            os.mkfifo(root / "pipe.json")
            for name in ["link.json", "directory.json", "pipe.json", "../owned.json"]:
                with self.subTest(name=name), self.assertRaises((ProjectionError, OSError)):
                    checked_file(root, name)

    def test_depth_limit_does_not_silently_truncate_payload(self):
        value = {}
        for _ in range(70):
            value = {"nested": value}
        with self.assertRaises(ProjectionError):
            project_value(value, self.roots)

    def prepare_fixture(self, root, attempt=4):
        replay = b'{"inputReceipts":{}}'
        (root / "m156-full-source-replay.json").write_bytes(replay)
        v8 = b'{"status":"native-correction-not-runtime-qualified"}'
        (root / "native-v8-interpreter-scope-declaration-correction.json").write_bytes(v8)
        contract = {"schemaVersion": 1, "chromiumVersion": VERSION, "officialCommit": COMMIT, "officialTree": TREE,
                    "status": "native-inputs-frozen-unqualified", "releaseReady": False,
                    "attempt": attempt, "inputs": {
                        "m156-full-source-replay.json": hashlib.sha256(replay).hexdigest(),
                        "native-v8-interpreter-scope-declaration-correction.json": hashlib.sha256(v8).hexdigest()}}
        name = f"m156-prebuild-attempt-{attempt}-contract.json"
        raw = json.dumps(contract).encode()
        (root / name).write_bytes(raw)
        return name, hashlib.sha256(raw).hexdigest()

    def test_explicit_current_freeze_preserves_new_correction_and_old_outputs(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            name, digest = self.prepare_fixture(root)
            previous = root / "previous"
            previous.mkdir(); (previous / "registry.json").write_bytes(b"preserved")
            registry = prepare(root, self.roots, root / "current", contract_name=name, contract_sha256=digest)
            self.assertEqual(registry["originalPrebuildContract"], name)
            self.assertEqual(registry["originalPrebuildContractSHA256"], digest)
            self.assertEqual(len(registry["receipts"]), 3)
            self.assertIn("native-v8-interpreter-scope-declaration-correction.json.projection.json",
                          {r["path"] for r in registry["receipts"]})
            self.assertEqual((previous / "registry.json").read_bytes(), b"preserved")
            self.assertFalse(registry["releaseReady"])
            self.assertEqual(verify_prepared(root / "current", contract_name=name, contract_sha256=digest, registry_sha256=hashlib.sha256((root / "current" / "registry.json").read_bytes()).hexdigest()), registry)
            with self.assertRaises(FileExistsError):
                prepare(root, self.roots, root / "current", contract_name=name, contract_sha256=digest)

    def test_missing_digest_wrong_freeze_and_changed_input_create_no_output(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            name, digest = self.prepare_fixture(root)
            cases = [(name, ""), (name, "0" * 64), ("../" + name, digest),
                     ("m156-prebuild-attempt-3-contract.json", digest)]
            for index, (chosen, expected) in enumerate(cases):
                output = root / f"rejected-{index}"
                with self.assertRaises((ProjectionError, OSError)):
                    prepare(root, self.roots, output, contract_name=chosen, contract_sha256=expected)
                self.assertFalse(output.exists())
            (root / "native-v8-interpreter-scope-declaration-correction.json").write_bytes(b"changed")
            with self.assertRaises(ProjectionError):
                prepare(root, self.roots, root / "tampered", contract_name=name, contract_sha256=digest)
            self.assertFalse((root / "tampered").exists())

    def test_filename_attempt_must_match_contract(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            name, _ = self.prepare_fixture(root)
            raw = json.loads((root / name).read_bytes()); raw["attempt"] = 3
            encoded = json.dumps(raw).encode(); (root / name).write_bytes(encoded)
            with self.assertRaises(ProjectionError):
                prepare(root, self.roots, root / "rejected", contract_name=name,
                        contract_sha256=hashlib.sha256(encoded).hexdigest())
            self.assertFalse((root / "rejected").exists())

    def test_prepared_store_detects_missing_extra_and_wrong_historical_freeze(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); name, digest = self.prepare_fixture(root)
            output = root / "current"
            prepare(root, self.roots, output, contract_name=name, contract_sha256=digest)
            with self.assertRaises(ProjectionError):
                verify_prepared(output, contract_name=name, contract_sha256="0" * 64, registry_sha256=hashlib.sha256((output / "registry.json").read_bytes()).hexdigest())
            extra = output / "unexpected.json"; extra.write_bytes(b"{}")
            with self.assertRaises(ProjectionError):
                verify_prepared(output, contract_name=name, contract_sha256=digest, registry_sha256=hashlib.sha256((output / "registry.json").read_bytes()).hexdigest())
            extra.unlink()
            (output / "native-v8-interpreter-scope-declaration-correction.json.projection.json").unlink()
            with self.assertRaises((ProjectionError, OSError)):
                verify_prepared(output, contract_name=name, contract_sha256=digest, registry_sha256=hashlib.sha256((output / "registry.json").read_bytes()).hexdigest())

    def test_prepared_store_refuses_invalid_schema_and_unsafe_public_payload(self):
        mutations = [lambda d: d.update(schemaVersion=True),
                     lambda d: d.update(receipt=None),
                     lambda d: d.update(releaseReady=True),
                     lambda d: d.update(payload={"path": "/Users/test/private"}),
                     lambda d: d.update(payload={"password": "synthetic-secret"}),
                     lambda d: d.update(originalReceiptSHA256="0" * 64)]
        for mutation in mutations:
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as folder:
                root = Path(folder); name, digest = self.prepare_fixture(root)
                output = root / "current"
                registry = prepare(root, self.roots, output, contract_name=name, contract_sha256=digest)
                record = next(r for r in registry["receipts"] if r["path"].startswith("native-v8"))
                target = output / record["path"]; doc = json.loads(target.read_bytes()); mutation(doc)
                data = json.dumps(doc).encode(); target.write_bytes(data)
                record["projectionSHA256"] = hashlib.sha256(data).hexdigest()
                if doc["originalReceiptSHA256"] != record["originalReceiptSHA256"]:
                    record["originalReceiptSHA256"] = doc["originalReceiptSHA256"]
                (output / "registry.json").write_text(json.dumps(registry))
                with self.assertRaises(ProjectionError):
                    verify_prepared(output, contract_name=name, contract_sha256=digest, registry_sha256=hashlib.sha256((output / "registry.json").read_bytes()).hexdigest())

    def test_independent_registry_digest_prevents_changed_payload_with_unchanged_original_hash(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); name, digest = self.prepare_fixture(root); output = root / "current"
            registry = prepare(root, self.roots, output, contract_name=name, contract_sha256=digest)
            pinned = hashlib.sha256((output / "registry.json").read_bytes()).hexdigest()
            record = next(r for r in registry["receipts"] if r["path"].startswith("native-v8"))
            target = output / record["path"]; doc = json.loads(target.read_bytes())
            # The hash of a private original does not authenticate the JSON
            # projection payload. Keep it unchanged while forging a claim.
            original = doc["originalReceiptSHA256"]
            doc["payload"]["runtimeVerified"] = True
            raw = json.dumps(doc).encode(); target.write_bytes(raw)
            record["projectionSHA256"] = hashlib.sha256(raw).hexdigest()
            (output / "registry.json").write_text(json.dumps(registry))
            self.assertEqual(doc["originalReceiptSHA256"], original)
            with self.assertRaisesRegex(ProjectionError, "Pinned projection registry changed"):
                verify_prepared(output, contract_name=name, contract_sha256=digest, registry_sha256=pinned)
            for invalid in ["", None, True, "x" * 64]:
                with self.subTest(invalid=invalid), self.assertRaises(ProjectionError):
                    verify_prepared(output, contract_name=name, contract_sha256=digest, registry_sha256=invalid)
