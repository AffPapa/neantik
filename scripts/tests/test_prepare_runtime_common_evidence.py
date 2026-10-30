import copy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import prepare_runtime_common_evidence as evidence


class CommonEvidencePreparationTests(unittest.TestCase):
    def fixture(self, root):
        rows = []
        for role in evidence.DESTINATIONS:
            path = root / (role + '.json')
            raw = json.dumps({'role': role}).encode()
            path.write_bytes(raw)
            rows.append({'role': role, 'source': str(path), 'sha256': hashlib.sha256(raw).hexdigest()})
        return {'schemaVersion': 1, 'inputs': rows}

    def test_same_source_populates_both_baseline_destinations(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve(); plan = self.fixture(root)
            historical = next(row for row in plan['inputs'] if row['role'] == 'historicalBaseline')
            publication = next(row for row in plan['inputs'] if row['role'] == 'publicationBaseline')
            publication.update(source=historical['source'], sha256=historical['sha256'])
            inputs = evidence.prepare(plan)
            out = root / 'staged'; evidence.stage(inputs, out)
            self.assertEqual(len(list(out.iterdir())), 8)
            self.assertEqual((out / 'security-baseline.json').read_bytes(), (out / 'release-security-baseline.json').read_bytes())
            for row in inputs:
                self.assertEqual((out / row.destination).read_bytes(), row.data)
                self.assertEqual((out / row.destination).stat().st_mode & 0o777, row.mode)

    def test_old_source_keyed_mapping_collision_missing_destination_refused(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve(); plan = self.fixture(root)
            plan['inputs'].pop()
            with self.assertRaises(ValueError): evidence.prepare(plan)
            self.assertFalse((root / 'output').exists())

    def test_schema_and_role_negative_controls(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve(); good = self.fixture(root)
            changes = [lambda p: p.update(schemaVersion=True), lambda p: p.update(extra=1),
                       lambda p: p['inputs'].append(copy.deepcopy(p['inputs'][0])),
                       lambda p: p['inputs'][0].update(role='unknown'),
                       lambda p: p['inputs'][0].update(role=p['inputs'][1]['role']),
                       lambda p: p['inputs'][0].update(extra=1),
                       lambda p: p['inputs'][0].update(sha256='x' * 64),
                       lambda p: p['inputs'][0].update(source='../outside'),
                       lambda p: p['inputs'][0].update(source=None)]
            for index, change in enumerate(changes):
                plan = copy.deepcopy(good); change(plan)
                with self.subTest(index=index), self.assertRaises((ValueError, OSError)): evidence.prepare(plan)

    def test_all_inputs_checked_before_output_creation(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve(); plan = self.fixture(root)
            plan['inputs'][-1]['sha256'] = '0' * 64
            with self.assertRaises(ValueError):
                evidence.stage(evidence.prepare(plan), root / 'output')
            self.assertFalse((root / 'output').exists())

    def test_retained_bytes_survive_path_replacement(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve(); plan = self.fixture(root)
            prepared = evidence.prepare(plan)
            path = Path(plan['inputs'][0]['source'])
            other = root / 'replacement'; other.write_bytes(b'different'); other.replace(path)
            evidence.stage(prepared, root / 'output')
            expected = next(item for item in prepared if item.destination == 'fingerprint-chromium.lock.json')
            self.assertEqual((root / 'output' / expected.destination).read_bytes(), expected.data)
            with self.assertRaises(ValueError): evidence.prepare(plan)

    def test_changed_in_place_read_refused(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve(); plan = self.fixture(root)
            original = os.read; changed = False
            def changing_read(fd, count):
                nonlocal changed
                data = original(fd, count)
                if not changed:
                    changed = True
                    Path(plan['inputs'][0]['source']).write_bytes(b'changed during read')
                return data
            with patch.object(evidence.os, 'read', side_effect=changing_read), self.assertRaises(ValueError):
                evidence.prepare(plan)

    def test_links_special_missing_and_oversized_inputs_refused(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve(); good = self.fixture(root)
            linked = root / 'link'; linked.symlink_to(good['inputs'][0]['source'])
            parent = root / 'linked-parent'; parent.symlink_to(root, target_is_directory=True)
            fifo = root / 'fifo'; os.mkfifo(fifo)
            large = root / 'large'; large.write_bytes(b'x' * (evidence.MAX_INPUT_BYTES + 1))
            for target in [linked, parent / Path(good['inputs'][0]['source']).name, fifo, large, root / 'missing', root]:
                plan = copy.deepcopy(good); plan['inputs'][0]['source'] = str(target)
                with self.subTest(path=target.name), self.assertRaises((ValueError, OSError)): evidence.prepare(plan)

    def test_existing_output_and_symlink_parent_refused(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve(); prepared = evidence.prepare(self.fixture(root))
            out = root / 'output'; out.mkdir(); marker = out / 'retained'; marker.write_bytes(b'old')
            with self.assertRaises(FileExistsError): evidence.stage(prepared, out)
            self.assertEqual(marker.read_bytes(), b'old')
            linked = root / 'parent-link'; linked.symlink_to(root, target_is_directory=True)
            with self.assertRaises(OSError): evidence.stage(prepared, linked / 'other')
            self.assertFalse((root / 'other').exists())

    def test_prepared_coverage_and_bytes_mutation_refused(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve(); prepared = evidence.prepare(self.fixture(root))
            bad = evidence.PreparedInput(prepared[0].destination, prepared[0].mode, prepared[0].sha256, b'changed')
            for inputs in [prepared[:-1], (prepared[0],) * 8, (bad,) + prepared[1:]]:
                with self.assertRaises(ValueError): evidence.stage(inputs, root / 'output')
            self.assertFalse((root / 'output').exists())

    def test_cli_preflight_and_redacted_failure(self):
        script = Path(evidence.__file__).resolve()
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve(); plan = self.fixture(root); path = root / 'plan.json'
            path.write_text(json.dumps(plan))
            command = [sys.executable, '-B', str(script), '--plan', str(path)]
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            receipt = json.loads(result.stdout)
            self.assertEqual(receipt['status'], 'preflight-only'); self.assertFalse(receipt['releaseQualified'])
            self.assertNotIn(str(root), result.stdout)
            for text in ['{"schemaVersion":1,"schemaVersion":1,"inputs":[]}', '{"inputs":"PRIVATE-CONTENT"}']:
                path.write_text(text)
                refused = subprocess.run(command, capture_output=True, text=True)
                self.assertEqual(refused.returncode, 1)
                self.assertNotIn('PRIVATE-CONTENT', refused.stderr); self.assertNotIn(str(root), refused.stderr)
                self.assertEqual(refused.stdout, '')


if __name__ == '__main__':
    unittest.main()
