import importlib.util
import json
import shutil
import tempfile
import unittest
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('mcp_docs', ROOT/'scripts/verify-mcp-documentation.py')
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)

class MCPDocumentationTests(unittest.TestCase):
    def test_current_catalog_is_covered(self):
        result = MODULE.verify()
        self.assertIn('template_list', result['tools'])
        self.assertEqual(result['toolCount'], len(result['tools']))
    def test_corrupt_claim_and_omitted_tool_are_detected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for name in ['README.md','README.en.md','Resources/Info.plist','CHANGELOG.md','Sources/NeAntik/MCPProfileManagement.swift','docs/mcp-capabilities.json','docs/MCP_GUIDE.md','docs/WEBKIT_PROFILES.md','docs/PRODUCT.md','Sources/NeAntik/HelpContent.swift','docs/ROADMAP.md','docs/NEANTIK_GLOBAL_PRODUCT_PLAN_2026.md','docs/NEANTIK_IMPROVEMENT_ROADMAP.md','docs/SOURCE_TO_SITE_HANDOFF.md','releases/' + max(ROOT.glob('releases/v*.json'), key=lambda p: tuple(map(int,p.stem[1:].split('.')))).name]:
                (root/name).parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(ROOT/name,root/name)
            manifest = root/'docs/mcp-capabilities.json'
            original = manifest.read_text()
            data=json.loads(original);data['toolCount']+=1;manifest.write_text(json.dumps(data))
            with self.assertRaisesRegex(ValueError,'manifest differs'): MODULE.verify(root)
            manifest.write_text(original)
            guide=root/'docs/MCP_GUIDE.md';guide.write_text(guide.read_text().replace('`template_list`','template-list'))
            with self.assertRaisesRegex(ValueError,'guide omits'): MODULE.verify(root)
    def test_webkit_proxy_guide_cannot_claim_a_route_that_is_disabled(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            for name in ['README.md','README.en.md','Resources/Info.plist','CHANGELOG.md','Sources/NeAntik/MCPProfileManagement.swift','docs/mcp-capabilities.json','docs/MCP_GUIDE.md','docs/WEBKIT_PROFILES.md','docs/PRODUCT.md','Sources/NeAntik/HelpContent.swift','docs/ROADMAP.md','docs/NEANTIK_GLOBAL_PRODUCT_PLAN_2026.md','docs/NEANTIK_IMPROVEMENT_ROADMAP.md','docs/SOURCE_TO_SITE_HANDOFF.md','releases/' + max(ROOT.glob('releases/v*.json'), key=lambda p: tuple(map(int,p.stem[1:].split('.')))).name]:
                (root/name).parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(ROOT/name,root/name)
            MODULE.verify(root)
            for name, before, after, error in [
                ('docs/MCP_GUIDE.md','WebKit is deferred and cannot be launched in the current Chromium-only release','WebKit can be launched in the current release','MCP guide WebKit availability claim'),
                ('docs/WEBKIT_PROFILES.md','профиль с прокси не запускается','профиль запускается с прокси','WebKit profile guide proxy claim'),
                ('Sources/NeAntik/HelpContent.swift','WebKit-профиль с прокси не запускается','WebKit-профиль с прокси запускается','In-app help WebKit proxy claim'),
            ]:
                guide=root/name;original=guide.read_text()
                self.assertIn(before, original)
                guide.write_text(original.replace(before, after, 1))
                with self.assertRaisesRegex(ValueError,error):
                    MODULE.verify(root)
                guide.write_text(original)
    def test_stale_read_only_product_claim_is_detected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            for name in ['README.md','README.en.md','Resources/Info.plist','CHANGELOG.md','Sources/NeAntik/MCPProfileManagement.swift','docs/mcp-capabilities.json','docs/MCP_GUIDE.md','docs/WEBKIT_PROFILES.md','docs/PRODUCT.md','Sources/NeAntik/HelpContent.swift','docs/ROADMAP.md','docs/NEANTIK_GLOBAL_PRODUCT_PLAN_2026.md','docs/NEANTIK_IMPROVEMENT_ROADMAP.md','docs/SOURCE_TO_SITE_HANDOFF.md','releases/' + max(ROOT.glob('releases/v*.json'), key=lambda p: tuple(map(int,p.stem[1:].split('.')))).name]:
                (root/name).parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(ROOT/name,root/name)
            p=root/'docs/PRODUCT.md';p.write_text(p.read_text().replace('18 management tools','17 management tools'))
            with self.assertRaisesRegex(ValueError,'permission counts'): MODULE.verify(root)

    def test_stale_roadmap_and_template_claims_are_detected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            for name in ['README.md','README.en.md','Resources/Info.plist','CHANGELOG.md','Sources/NeAntik/HelpContent.swift', 'docs/ROADMAP.md', 'docs/NEANTIK_GLOBAL_PRODUCT_PLAN_2026.md', 'docs/NEANTIK_IMPROVEMENT_ROADMAP.md','docs/SOURCE_TO_SITE_HANDOFF.md', 'releases/' + max(ROOT.glob('releases/v*.json'), key=lambda p: tuple(map(int,p.stem[1:].split('.')))).name]:
                (root/name).parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(ROOT/name,root/name)
            MODULE.verify_current_product_claims(root)
            roadmap=root/'docs/ROADMAP.md';original=roadmap.read_text()
            latest_path=max((root/'releases').glob('v*.json'),key=lambda p:tuple(map(int,p.stem[1:].split('.'))))
            latest=json.loads(latest_path.read_text())
            roadmap.write_text(original.replace(f"{latest['version']} ({latest['build']})", '0.8.24 (136)', 1))
            with self.assertRaisesRegex(ValueError, 'docs/ROADMAP.md'): MODULE.verify_current_product_claims(root)
            roadmap.write_text(original)
            for filename in ('NEANTIK_GLOBAL_PRODUCT_PLAN_2026.md', 'NEANTIK_IMPROVEMENT_ROADMAP.md'):
                p=root/'docs'/filename;original=p.read_text()
                p.write_text(original.replace('Current public release:', 'Obsolete public release:'))
                with self.assertRaisesRegex(ValueError, 'roadmap release claim'): MODULE.verify_current_product_claims(root)
                p.write_text(original)
            changelog=root/'CHANGELOG.md';original=changelog.read_text()
            changelog.write_text(original.replace('## Direct ', '## Historical ', 1))
            with self.assertRaisesRegex(ValueError, 'no release changelog entry'): MODULE.verify_current_product_claims(root)
            changelog.write_text(original)
            help_path=root/'Sources/NeAntik/HelpContent.swift';help_path.write_text(help_path.read_text()+'\nпрокси с авторизацией требует собственного пароля')
            with self.assertRaisesRegex(ValueError, 'templates copy'): MODULE.verify_current_product_claims(root)

    def test_stale_readme_version_build_url_and_report_are_detected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            latest_path = max(ROOT.glob('releases/v*.json'), key=lambda p: tuple(map(int, p.stem[1:].split('.'))))
            latest = json.loads(latest_path.read_text())
            for name in ['README.md', 'README.en.md', 'Resources/Info.plist', 'CHANGELOG.md', 'docs/ROADMAP.md',
                         'Sources/NeAntik/HelpContent.swift', 'docs/NEANTIK_GLOBAL_PRODUCT_PLAN_2026.md',
                         'docs/NEANTIK_IMPROVEMENT_ROADMAP.md', 'docs/SOURCE_TO_SITE_HANDOFF.md', 'releases/' + latest_path.name]:
                (root / name).parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(ROOT / name, root / name)
            MODULE.verify_current_product_claims(root)
            for name in ['README.md', 'README.en.md']:
                path = root / name
                original = path.read_text()
                latest_label = f"NeAntik {latest['version']} ({latest['build']})"
                claim_start = original.index(latest_label)
                report_marker = f"releases/{latest['tag']}.json"
                report_start = original.index(report_marker, claim_start)
                changes = [
                    (latest_label, 'NeAntik 0.0.1 (1)'),
                    (f"({latest['build']}), public alpha", '(99999), public alpha'),
                    (f"releases/tag/{latest['tag']}", 'releases/tag/v0.0.1'),
                ]
                for before, after in changes:
                    with self.subTest(readme=name, field=before):
                        self.assertIn(before, original)
                        path.write_text(original.replace(before, after, 1))
                        with self.assertRaisesRegex(ValueError, 'README release claim'):
                            MODULE.verify_current_product_claims(root)
                        path.write_text(original)
                mutated_report = (original[:report_start]
                                  + original[report_start:].replace(report_marker, 'releases/obsolete.json', 1))
                with self.subTest(readme=name, field=report_marker):
                    path.write_text(mutated_report)
                    with self.assertRaisesRegex(ValueError, 'README release claim'):
                        MODULE.verify_current_product_claims(root)
                    path.write_text(original)

if __name__=='__main__': unittest.main()
