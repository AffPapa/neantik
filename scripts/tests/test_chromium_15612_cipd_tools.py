import ast
import base64
import copy
import hashlib
import tempfile
import unittest
from pathlib import Path

import chromium_15612_cipd_tools as module
from chromium_15612_generated_cache import M156CacheError


def tag(raw):
    return base64.urlsafe_b64encode(hashlib.sha256(raw).digest() + b'\x02').decode()


def deps_fixture(*, dawn=False):
    variables = {'gn_version': module.GN_VERSION, 'ninja_package': 'infra/3pp/tools/ninja/',
                 'ninja_version': module.NINJA_VERSION, 'dawn_ninja_version': module.NINJA_VERSION}
    if dawn:
        dependencies = "{'third_party/ninja': {'packages': [{'package': 'infra/3pp/tools/ninja/${{platform}}', 'version': Var('dawn_ninja_version')}], 'dep_type': 'cipd'}}"
    else:
        dependencies = "{'src/buildtools/mac': {'packages': [{'package': 'gn/gn/mac-${{arch}}', 'version': Var('gn_version')}], 'dep_type': 'cipd', 'condition': 'host_os == \"mac\"'}, 'src/third_party/ninja': {'packages': [{'package': Var('ninja_package') + '${{platform}}', 'version': Var('ninja_version')}], 'dep_type': 'cipd', 'condition': 'non_git_source'}}"
    return ('vars = ' + repr(variables) + '\ndeps = ' + dependencies).encode()


def manifest_fixture():
    files = {'gn': b'owned executable', '.versions/gn.cipd_version': b'owned version'}
    manifest = {'format_version': '1.1', 'package_name': module.SPECS['gn']['package'],
                'version_file': '.versions/gn.cipd_version', 'install_mode': 'copy', 'actual_install_mode': 'copy',
                'files': [{'name': name, 'size': len(raw), 'hash': tag(raw), **({'executable': True} if name == 'gn' else {})}
                          for name, raw in files.items()]}
    return manifest, files


class CIPDOriginTests(unittest.TestCase):
    def test_selected_root_and_nested_dawn_deps_without_execution(self):
        self.assertEqual(set(module.deps_origins(deps_fixture())), {'gn', 'ninja'})
        self.assertEqual(set(module.deps_origins(deps_fixture(dawn=True), dawn=True)), {'dawn-ninja'})

    def test_version_platform_package_condition_and_unknown_expression_fail(self):
        original = deps_fixture()
        for old, new in [(module.GN_VERSION, 'git_revision:' + '0' * 40),
                         (module.NINJA_VERSION, 'version:3@other'), ('mac-${{arch}}', 'linux-${{arch}}'),
                         ('infra/3pp/tools/ninja/', 'other/'), ('non_git_source', 'checkout_linux'),
                         ("Var('gn_version')", 'unknown()')]:
            with self.subTest(new=new), self.assertRaises(M156CacheError):
                module.deps_origins(original.replace(old.encode(), new.encode()))

    def test_unpack_dynamic_duplicate_keys_and_later_update_fail(self):
        original = deps_fixture().decode()
        for raw in [original[:-1] + ', **{}}', original[:-1] + ', ("x" + "y"): {}}',
                    original[:-1] + ', "src/buildtools/mac": {}}', original + '\ndeps.update({})']:
            with self.subTest(raw=raw[-60:]), self.assertRaises(M156CacheError): module.deps_origins(raw.encode())
        with self.assertRaises(M156CacheError): module.dictionary(ast.parse('vars = {}\nvars = {}'), 'vars')

    def test_cipd_hash_algorithm_length_and_encoding_are_not_ignored(self):
        self.assertEqual(module.tagged_sha256(tag(b'owned')), hashlib.sha256(b'owned').hexdigest())
        for bad in [tag(b'owned') + '=', '0' * 40, 'x' * 44, tag(b'owned')[:-1] + '/',
                    base64.urlsafe_b64encode(hashlib.sha256(b'owned').digest() + b'\x01').decode(),
                    base64.urlsafe_b64encode(b'123\x02').decode()]:
            with self.subTest(bad=bad), self.assertRaises(M156CacheError): module.tagged_sha256(bad)


class CIPDPayloadTests(unittest.TestCase):
    def test_readonly_installed_copy_matches_files_modes_and_directories(self):
        manifest, files = manifest_fixture(); members, payload = module.manifest_members(manifest, module.SPECS['gn'])
        with tempfile.TemporaryDirectory(prefix='neantik-cipd-owned-') as temp:
            root = Path(temp); (root / 'installed').mkdir(mode=0o755); (root / 'installed/.versions').mkdir(mode=0o755)
            for name, raw in files.items():
                p = root / 'installed' / name; p.write_bytes(raw); p.chmod(int(members[name]['mode'], 8))
            module.verify_installed(root, members, payload, 'installed')

    def test_copy_faults_are_refused_independently_of_package_instance(self):
        for fault in ['extra', 'bytes', 'mode', 'missing', 'intermediate-symlink', 'hardlink']:
            with self.subTest(fault=fault), tempfile.TemporaryDirectory(prefix='neantik-cipd-fault-') as temp:
                root = Path(temp); installed = root / 'parent/installed'; installed.mkdir(parents=True); (installed / '.versions').mkdir()
                manifest, files = manifest_fixture(); members, payload = module.manifest_members(manifest, module.SPECS['gn'])
                for name, raw in files.items():
                    p = installed / name; p.write_bytes(raw); p.chmod(int(members[name]['mode'], 8))
                p = installed / 'gn'
                if fault == 'extra': (installed / 'foreign').write_bytes(b'foreign')
                elif fault == 'bytes': p.chmod(0o755); p.write_bytes(b'owned executablX'); p.chmod(0o555)
                elif fault == 'mode': p.chmod(0o755)
                elif fault == 'missing': p.unlink()
                elif fault == 'hardlink': (root / 'extra-link').hardlink_to(p)
                else:
                    (root / 'parent').rename(root / 'moved'); (root / 'parent').symlink_to(root / 'moved')
                with self.assertRaises((M156CacheError, OSError)): module.verify_installed(root, members, payload, 'parent/installed')

    def test_manifest_schema_package_size_boolean_hash_and_path_faults_fail(self):
        good, _ = manifest_fixture()
        cases = []
        for field, bad in [('package_name', 'unrelated'), ('format_version', '2'), ('install_mode', 'symlink'),
                           ('actual_install_mode', 'symlink'), ('version_file', 'elsewhere')]:
            d = copy.deepcopy(good); d[field] = bad; cases.append(d)
        for field, bad in [('size', True), ('size', 8 * 1024 * 1024 + 1), ('name', '../escape'),
                           ('executable', False), ('executable', 1), ('hash', 'x' * 44)]:
            d = copy.deepcopy(good); d['files'][0][field] = bad; cases.append(d)
        d = copy.deepcopy(good); d['extra'] = True; cases.append(d)
        d = copy.deepcopy(good); d['files'][1]['name'] = 'gn'; cases.append(d)
        for d in cases:
            with self.subTest(d=d), self.assertRaises(M156CacheError): module.manifest_members(d, module.SPECS['gn'])


if __name__ == '__main__': unittest.main()
