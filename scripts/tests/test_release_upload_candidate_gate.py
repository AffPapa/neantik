"""Exercise dispatch with mocked local validation and transport; no network."""
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'neantik-affpapa-release'


class UploadCandidateGateTests(unittest.TestCase):
    def test_failed_dmg_cannot_be_masked_by_successful_zip(self):
        source = SCRIPT.read_text().rsplit('main "$@"', 1)[0]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            verifier = root / 'scripts/verify-direct-notarized-dmg.sh'
            verifier.parent.mkdir()
            verifier.write_text('#!/bin/bash\nexit 23\n')
            verifier.chmod(0o700)
            commands = source + '''
PROJECT_ROOT="$1"
python3() {
    if [[ "$1" == "-" ]]; then printf '/fixture/artifact\\n';
    else printf 'ZIP_CHECK_REACHED\\n'; fi
}
if verify_local_artifacts /fixture/manifest /fixture; then exit 0; else exit 1; fi
'''
            result = subprocess.run(['bash', '-c', commands, str(SCRIPT), str(root)],
                                    capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn('ZIP_CHECK_REACHED', result.stdout)

    def dispatch(self, validation_status):
        source = SCRIPT.read_text().rsplit('main "$@"', 1)[0]
        with tempfile.TemporaryDirectory() as directory:
            payload = Path(directory).resolve() / 'release.json'
            commands = source + '''
preflight_access() { :; }
validate_local_candidate() { printf 'VALIDATE:%s\\n' "$1"; return ''' + str(validation_status) + '''; }
upload_file() { printf 'UPLOAD:%s\\n' "$1"; }
main upload "$1"
'''
            return subprocess.run(['bash', '-c', commands, str(SCRIPT), str(payload)],
                                  capture_output=True, text=True), payload

    def test_failed_candidate_validation_never_uploads(self):
        result, payload = self.dispatch(1)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('VALIDATE:' + str(payload.parent), result.stdout)
        self.assertNotIn('UPLOAD:', result.stdout)

    def test_validated_candidate_precedes_single_file_upload(self):
        result, payload = self.dispatch(0)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(),
                         ['VALIDATE:' + str(payload.parent), 'UPLOAD:' + str(payload)])

    def test_shared_validator_keeps_manifest_and_notarization_gates(self):
        source = SCRIPT.read_text()
        body = source.split('validate_local_candidate() {', 1)[1].split('prepare_release() {', 1)[0]
        self.assertIn('python3 "$VALIDATOR" "$directory" "$live_manifest"', body)
        self.assertIn('verify_release_artifacts_with_policy_fallback', body)
        prepare = source.split('prepare_release() {', 1)[1].split('verify_live_metadata()', 1)[0]
        self.assertLess(prepare.index('validate_local_candidate'), prepare.index('remote neantik-release-abort'))
