#!/usr/bin/env python3
"""Keep public MCP capabilities tied to the actual native tool catalog."""
from __future__ import annotations
import json
import plistlib
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
    if ('WebKit is deferred and cannot be launched in the current Chromium-only release' not in guide
            or 'WebKit is **not available in the current Chromium-only release**' not in guide
            or "the app applies Apple's proxy configuration" in guide):
        raise ValueError('MCP guide WebKit availability claim differs from the Chromium-only release')
    webkit_guide = (root / 'docs/WEBKIT_PROFILES.md').read_text()
    if ('профиль с прокси не запускается' not in webkit_guide
            or 'для работы через прокси' not in webkit_guide
            or 'В Dev профильный прокси назначается' in webkit_guide):
        raise ValueError('WebKit profile guide proxy claim differs from the native fail-closed policy')
    product = (root / 'docs/PRODUCT.md').read_text()
    declared = re.search(r'(\d+) management tools \((\d+) in\s+read mode\)', product)
    if not declared or tuple(map(int, declared.groups())) != (expected['toolCount'], expected['readToolCount']):
        raise ValueError('Product MCP permission counts differ from native catalog')
    if 'secret access or write API' in product:
        raise ValueError('Product still excludes supported MCP management')
    verify_current_product_claims(root)
    return expected


def verify_current_product_claims(root: Path) -> None:
    reports = [json.loads(path.read_text()) for path in (root / 'releases').glob('v*.json')]
    if not reports:
        raise ValueError('Published release evidence is missing')
    latest = max(reports, key=lambda item: tuple(int(v) for v in item['version'].split('.')))
    verify_roadmap_release_claim(root, latest)
    for filename in ('README.md', 'README.en.md'):
        text = (root / filename).read_text()
        # Both the introductory announcement and download label describe the
        # current release. A correct link must not mask a stale earlier build.
        intro = text.split('\n## ', 1)[0]
        intro_claims = re.findall(r'(\d+\.\d+\.\d+) \((\d+)\)', intro)
        release_url = f"https://github.com/AffPapa/neantik/releases/tag/{latest['tag']}"
        intro_links = re.findall(r'https://github\.com/AffPapa/neantik/releases/tag/[^)\s]+', intro)
        claim = re.search(r'\[NeAntik (\d+\.\d+\.\d+) \((\d+)\)[^\]]*\]\((https://github\.com/AffPapa/neantik/releases/tag/v[^)]+)\)', text)
        claim_paragraph = ''
        if claim:
            paragraph_end = text.find('\n\n', claim.end())
            claim_paragraph = text[claim.start():paragraph_end if paragraph_end >= 0 else len(text)]
        if (not intro_claims or any(pair != (latest['version'], str(latest['build'])) for pair in intro_claims)
                or not intro_links or any(link != release_url for link in intro_links)
                or not claim or claim.groups() != (latest['version'], str(latest['build']),
                release_url)
                or f"releases/{latest['tag']}.json" not in claim_paragraph):
            raise ValueError('README release claim differs from published evidence: ' + filename)
    for filename in ('NEANTIK_GLOBAL_PRODUCT_PLAN_2026.md', 'NEANTIK_IMPROVEMENT_ROADMAP.md'):
        text = (root / 'docs' / filename).read_text()
        current_claim = re.search(r'(?m)^> Current public release: (.+)$', text)
        normalized_claim = re.sub(r'\s+', '', current_claim.group(1)) if current_claim else ''
        if (not current_claim
                or f"{latest['version']}/build{latest['build']}" not in normalized_claim
                or latest['runtime']['chromiumVersion'] not in normalized_claim
                or f"releases/{latest['tag']}.json" not in normalized_claim):
            raise ValueError('Current roadmap release claim differs from published evidence: ' + filename)
    info = plistlib.loads((root / 'Resources/Info.plist').read_bytes())
    heading = f"## Direct {info['CFBundleShortVersionString']} ({info['CFBundleVersion']})"
    if heading not in (root / 'CHANGELOG.md').read_text():
        raise ValueError('Current app version has no release changelog entry')
    help_text = (root / 'Sources/NeAntik/HelpContent.swift').read_text()
    if ('WebKitProxyFeature.launchEnabled' not in help_text
            or 'WebKit-профиль с прокси не запускается' not in help_text
            or 'прямое подключение вместо прокси не используется' not in help_text
            or 'профиль с прокси использует отдельный встроенный runtime' not in help_text
            or 'не подтверждают фактический маршрут окна' not in help_text
            or 'настройки применяются к отдельному хранилищу сайтов' in help_text):
        raise ValueError('In-app help WebKit proxy claim differs from the native fail-closed policy')
    if 'прокси с авторизацией требует собственного пароля' in help_text:
        raise ValueError('Help incorrectly claims templates copy proxy configuration')
    if 'работающие профили закрывать не нужно' not in help_text:
        raise ValueError('Help omits additive snapshot import semantics')


def verify_roadmap_release_claim(root: Path, latest: dict) -> None:
    """Keep private live status out of public docs and bind the public snapshot."""
    path = root / 'docs' / 'ROADMAP.md'
    if not path.is_file():
        raise ValueError('Current roadmap is missing: docs/ROADMAP.md')
    text = path.read_text()
    paragraphs = text.split('\n\n', 2)
    intro = paragraphs[1] if len(paragraphs) > 1 else ''
    if ('NEXT_1_0_SLICES.md' not in intro
            or 'private maintainer checkpoint' not in intro.lower()
            or re.search(r'\d+\.\d+\.\d+ \(\d+\)', intro)
            or 'releases/tag/' in intro):
        raise ValueError('Public roadmap must identify the private checkpoint and link the public acceptance plan: docs/ROADMAP.md')
    release_label = f"{latest['version']} ({latest['build']})"
    release_url = latest.get('releaseUrl') or f"https://github.com/AffPapa/neantik/releases/tag/{latest['tag']}"
    report_path = f"releases/{latest['tag']}.json"
    site = latest.get('site') or {}
    site_version = site.get('liveVersion')
    site_build = site.get('liveBuild')
    # The historical snapshot remains bound to its immutable release report.
    historical = text.partition('\n## Исторический срез\n\n')[2].split('\n\n', 1)[0]
    linked_claim = f"[{release_label}]({release_url})"
    if (not historical or linked_claim not in historical or report_path not in historical
            or (site_version and f"{site_version} ({site_build})" not in historical)
            or (site.get('updated') is False and 'не опубликовано' not in historical)):
        raise ValueError('Historical roadmap release claim differs from evidence: docs/ROADMAP.md')


if __name__ == '__main__':
    report = verify()
    print(f"MCP documentation verified: {report['toolCount']} management / {report['readToolCount']} read tools")
