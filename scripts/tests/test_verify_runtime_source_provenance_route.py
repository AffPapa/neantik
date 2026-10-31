import importlib.util
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
spec = importlib.util.spec_from_file_location('verify_source_cli', SCRIPTS / 'verify-runtime-source-provenance.py')
M = importlib.util.module_from_spec(spec)
spec.loader.exec_module(M)


class LiveRouteTests(unittest.TestCase):
    def test_m154_uses_dedicated_live_snapshot_verifier(self):
        document = {'targetChromiumVersion': '154.0.8037.93'}
        with patch.object(M, 'verify_candidate_document') as verify, patch.object(M, 'build_provenance') as build:
            M.verify_live_source(document, Path('/src'), Path('/project'))
            verify.assert_called_once_with(document, project_root=Path('/project'), source_root=Path('/src'))
            build.assert_not_called()

    def test_m154_failure_remains_fatal(self):
        with patch.object(M, 'verify_candidate_document', side_effect=M.M154EvidenceError('changed source')):
            with self.assertRaises(M.SourceProvenanceError):
                M.verify_live_source({'targetChromiumVersion':'154.0.8037.93'}, Path('/src'), Path('/project'))

    def test_older_route_retains_fresh_equality_check(self):
        with patch.object(M, 'build_provenance', return_value={'old':True}), patch.object(M, 'verify_candidate_document') as verify:
            M.verify_live_source({'old':True}, Path('/src'), Path('/project'))
            with self.assertRaises(M.SourceProvenanceError):
                M.verify_live_source({'old':False}, Path('/src'), Path('/project'))
            verify.assert_not_called()
