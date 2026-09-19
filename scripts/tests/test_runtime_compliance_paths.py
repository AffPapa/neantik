import ast
from pathlib import Path
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'verify-runtime-compliance.sh'


class RuntimeCompliancePathsTests(unittest.TestCase):
    def test_document_names_cannot_escape_root_or_follow_symlinks(self):
        python = SCRIPT.read_text().split("python3 - <<'PY'\n", 1)[1].split('\nPY\n', 1)[0]
        tree = ast.parse(python)
        functions = [node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name in ('fail', 'checked_file')]
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            scope = {'root': root}
            exec(compile(ast.Module(body=functions, type_ignores=[]), str(SCRIPT), 'exec'), scope)
            name = 'THIRD-PARTY-NOTICES.html'
            target = root / name
            target.write_text('synthetic notices')
            self.assertEqual(scope['checked_file']({'file': name}, name), target)
            for invalid in ('../' + name, str(target), '', 'elsewhere.html'):
                with self.subTest(invalid=invalid), self.assertRaises(SystemExit):
                    scope['checked_file']({'file': invalid}, name)
            target.unlink()
            outside = root / 'synthetic-outside'
            outside.write_text('not packaged')
            target.symlink_to(outside)
            with self.assertRaises(SystemExit):
                scope['checked_file']({'file': name}, name)
