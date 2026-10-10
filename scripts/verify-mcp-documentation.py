#!/usr/bin/env python3
"""Keep public MCP capabilities tied to the actual native tool catalog."""
from __future__ import annotations
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def capabilities(root: Path) -> dict:
    source = (root / 'Sources/NeAntik/MCPProfileManagement.swift').read_text()
    groups = []
    for name in ('readTools', 'writeTools'):
        match = re.search(r'static let ' + name + r' = \[([^\]]+)\]', source)
        if match is None:
            raise ValueError('Native MCP catalog is missing')
        groups.append(re.findall(r'"([a-z_]+)"', match[1]))
    tools = ['workspace_list_profiles', 'workspace_list_profiles_page'] + groups[0] + groups[1]
    if len(tools) != len(set(tools)):
        raise ValueError('Native MCP catalog contains duplicates')
    return dict(schemaVersion=1, toolCount=len(tools), readToolCount=2 + len(groups[0]), tools=sorted(tools))


def verify(root: Path = ROOT) -> dict:
    expected = capabilities(root)
    published = json.loads((root / 'docs/mcp-capabilities.json').read_text())
    if published != expected:
        raise ValueError('MCP capability manifest differs from native tool catalog')
    guide = (root / 'docs/MCP_GUIDE.md').read_text()
    if any('`' + name + '`' not in guide for name in expected['tools']):
        raise ValueError('MCP guide omits an advertised native tool')
    product = (root / 'docs/PRODUCT.md').read_text()
    declared = re.search(r'(\d+) management tools \((\d+) in\s+read mode\)', product)
    if not declared or tuple(map(int, declared.groups())) != (expected['toolCount'], expected['readToolCount']):
        raise ValueError('Product MCP permission counts differ from native catalog')
    if 'secret access or write API' in product:
        raise ValueError('Product still excludes supported MCP management')
    return expected


if __name__ == '__main__':
    report = verify()
    print(f"MCP documentation verified: {report['toolCount']} management / {report['readToolCount']} read tools")
