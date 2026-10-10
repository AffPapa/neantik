"""Event patch has distinct ownership; old contracts never acquire it."""
import copy
import json
import sys
import unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import chromium_15540_semantic_corrections as corrections

ROOT = Path(__file__).resolve().parents[2]


class AudioEventSourceBindingTests(unittest.TestCase):
    def setUp(self):
        self.manifest = json.loads((ROOT / 'runtime/chromium-15540-semantic-v5-corrections-manifest.json').read_text())

    def test_seven_distinct_vectors_with_two_event_files(self):
        images = corrections.verify_manifest(ROOT, self.manifest)
        self.assertEqual(len(images), 13)
        event = self.manifest['patches'][-1]
        self.assertEqual(event['vector'], 'audio-events')
        self.assertEqual(event['dependsOn'], [])
        self.assertEqual({f['path'] for f in event['files']}, corrections.PATCHES['audio-events'][1])
        self.assertFalse(self.manifest['releaseReady'])

    def test_old_variant_cannot_silently_acquire_event_patch(self):
        m = copy.deepcopy(self.manifest)
        m['semanticCorrectionSet'] = 'canvas-audio-webgl-native-webrtc-layout-text-v4'
        with self.assertRaises(ValueError):
            corrections.verify_manifest(ROOT, m)

    def test_event_vector_cannot_claim_general_event_or_audio_processing_ownership(self):
        for path in ('third_party/blink/renderer/core/events/error_event.cc', 'third_party/blink/renderer/modules/webaudio/realtime_analyser.cc'):
            m = copy.deepcopy(self.manifest)
            m['patches'][-1]['files'][0]['path'] = path
            with self.assertRaises(ValueError):
                corrections.verify_manifest(ROOT, m)

    def test_patch_hash_and_event_dependencies_cannot_be_substituted(self):
        for key, value in (('sha256', '0' * 64), ('dependsOn', ['canvas'])):
            m = copy.deepcopy(self.manifest)
            m['patches'][-1][key] = value
            with self.assertRaises(ValueError):
                corrections.verify_manifest(ROOT, m)


if __name__ == '__main__':
    unittest.main()
