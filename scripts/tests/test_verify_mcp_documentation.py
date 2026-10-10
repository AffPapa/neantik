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
            for name in ['Sources/NeAntik/MCPProfileManagement.swift','docs/mcp-capabilities.json','docs/MCP_GUIDE.md','docs/PRODUCT.md','Sources/NeAntik/HelpContent.swift','docs/NEANTIK_GLOBAL_PRODUCT_PLAN_2026.md','docs/NEANTIK_IMPROVEMENT_ROADMAP.md','docs/SOURCE_TO_SITE_HANDOFF.md','releases/' + max(ROOT.glob('releases/v*.json'), key=lambda p: tuple(map(int,p.stem[1:].split('.')))).name]:
                (root/name).parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(ROOT/name,root/name)
            manifest = root/'docs/mcp-capabilities.json'
            original = manifest.read_text()
            data=json.loads(original);data['toolCount']+=1;manifest.write_text(json.dumps(data))
            with self.assertRaisesRegex(ValueError,'manifest differs'): MODULE.verify(root)
            manifest.write_text(original)
            guide=root/'docs/MCP_GUIDE.md';guide.write_text(guide.read_text().replace('`template_list`','template-list'))
            with self.assertRaisesRegex(ValueError,'guide omits'): MODULE.verify(root)
    def test_stale_read_only_product_claim_is_detected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            for name in ['Sources/NeAntik/MCPProfileManagement.swift','docs/mcp-capabilities.json','docs/MCP_GUIDE.md','docs/PRODUCT.md','Sources/NeAntik/HelpContent.swift','docs/NEANTIK_GLOBAL_PRODUCT_PLAN_2026.md','docs/NEANTIK_IMPROVEMENT_ROADMAP.md','docs/SOURCE_TO_SITE_HANDOFF.md','releases/' + max(ROOT.glob('releases/v*.json'), key=lambda p: tuple(map(int,p.stem[1:].split('.')))).name]:
                (root/name).parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(ROOT/name,root/name)
            p=root/'docs/PRODUCT.md';p.write_text(p.read_text().replace('18 management tools','17 management tools'))
            with self.assertRaisesRegex(ValueError,'permission counts'): MODULE.verify(root)

    def test_stale_roadmap_and_template_claims_are_detected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            for name in ['Sources/NeAntik/HelpContent.swift', 'docs/NEANTIK_GLOBAL_PRODUCT_PLAN_2026.md', 'docs/NEANTIK_IMPROVEMENT_ROADMAP.md','docs/SOURCE_TO_SITE_HANDOFF.md', 'releases/' + max(ROOT.glob('releases/v*.json'), key=lambda p: tuple(map(int,p.stem[1:].split('.')))).name]:
                (root/name).parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(ROOT/name,root/name)
            MODULE.verify_current_product_claims(root)
            for filename in ('NEANTIK_GLOBAL_PRODUCT_PLAN_2026.md', 'NEANTIK_IMPROVEMENT_ROADMAP.md', 'SOURCE_TO_SITE_HANDOFF.md'):
                p=root/'docs'/filename;original=p.read_text()
                p.write_text(original.replace('Current public release:', 'Obsolete public release:'))
                with self.assertRaisesRegex(ValueError, 'roadmap release claim'): MODULE.verify_current_product_claims(root)
                p.write_text(original)
            help_path=root/'Sources/NeAntik/HelpContent.swift';help_path.write_text(help_path.read_text()+'\nпрокси с авторизацией требует собственного пароля')
            with self.assertRaisesRegex(ValueError, 'templates copy'): MODULE.verify_current_product_claims(root)

if __name__=='__main__': unittest.main()
