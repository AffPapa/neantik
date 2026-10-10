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
            for name in ['Sources/NeAntik/MCPProfileManagement.swift','docs/mcp-capabilities.json','docs/MCP_GUIDE.md','docs/PRODUCT.md']:
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
            for name in ['Sources/NeAntik/MCPProfileManagement.swift','docs/mcp-capabilities.json','docs/MCP_GUIDE.md','docs/PRODUCT.md']:
                (root/name).parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(ROOT/name,root/name)
            p=root/'docs/PRODUCT.md';p.write_text(p.read_text().replace('18 management tools','17 management tools'))
            with self.assertRaisesRegex(ValueError,'permission counts'): MODULE.verify(root)

if __name__=='__main__': unittest.main()
