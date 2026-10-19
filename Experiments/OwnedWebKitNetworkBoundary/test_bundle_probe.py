"""Environment boundary controls, not native or release evidence."""
import importlib.util
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).parent))
spec = importlib.util.spec_from_file_location('bundle_probe', Path(__file__).with_name('bundle_probe.py'))
module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)


class EnvironmentTests(unittest.TestCase):
    def test_fixed_paths_replace_all_inherited_loader_paths(self):
        supplied = {'DYLD_INSERT_LIBRARIES': '/outside', '__XPC_DYLD_INSERT_LIBRARIES': '/outside',
                    'DYLD_FRAMEWORK_PATH': '/outside', 'WEBKIT_UNSET_DYLD_FRAMEWORK_PATH': 'NO',
                    'PATH': '/usr/bin'}
        result = module.environment_for_bundle(supplied, Path('/owned/QA.app'), True)
        self.assertNotIn('DYLD_INSERT_LIBRARIES', result)
        self.assertNotIn('__XPC_DYLD_INSERT_LIBRARIES', result)
        self.assertEqual(result['DYLD_FRAMEWORK_PATH'], '/owned/QA.app/Contents/Frameworks')
        self.assertEqual(result['__XPC_DYLD_LIBRARY_PATH'], result['DYLD_FRAMEWORK_PATH'])
        self.assertEqual(supplied['DYLD_FRAMEWORK_PATH'], '/outside')

    def test_rpath_only_control_has_no_loader_environment(self):
        result = module.environment_for_bundle({'__XPC_DYLD_LIBRARY_PATH': '/outside', 'PATH': '/usr/bin'},
                                               Path('/owned/QA.app'), False)
        self.assertEqual(result, {'PATH': '/usr/bin'})


if __name__ == '__main__': unittest.main()
