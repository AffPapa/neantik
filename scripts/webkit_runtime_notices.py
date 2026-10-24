#!/usr/bin/env python3
"""Install and verify scoped notices for the owned WebKit runtime slice.

This accounts for the bundled Swift CompatibilitySpan library, preserves the
exact pinned WebCore LGPL-2 and LGPL-2.1 texts, and adds source-mapped ANGLE notices.
It does not determine per-file license applicability or close WebKit source,
notice, relinking, or distribution obligations.
"""
from __future__ import annotations

import argparse
import hashlib
import html
import json
import os
from pathlib import Path
from pathlib import PurePosixPath
import re
import shutil
import stat
import sys
import tempfile


PROJECT_ROOT = Path(__file__).resolve().parents[1]
LICENSE_SOURCE = Path("runtime/licenses/Swift-6.4.0-Runtime-Library-Exception-LICENSE.txt")
LICENSE_NAME = "Swift-6.4.0-Runtime-Library-Exception-LICENSE.txt"
LICENSE_SHA256 = "770af8291f708538d8ff885a0bbc4e045cd700531741c4f99528d435c14d7f55"
LICENSE_DESTINATION = Path("Contents/Resources/NeAntikRuntimeLicenses") / LICENSE_NAME
WEBCORE_LGPL2_SOURCE = Path("docs/evidence/third-party/webcore/LICENSE-LGPL-2")
WEBCORE_LGPL2_NAME = "WebCore-LICENSE-LGPL-2.txt"
WEBCORE_LGPL2_SHA256 = "7555fa34bc131a75ca56d65c40cc1ea8f9515d23e353d4c15d58573a042f7805"
WEBCORE_LGPL2_DESTINATION = (
    Path("Contents/Resources/NeAntikRuntimeLicenses") / WEBCORE_LGPL2_NAME
)
WEBCORE_LGPL21_SOURCE = Path("docs/evidence/third-party/webcore/LICENSE-LGPL-2.1")
WEBCORE_LGPL21_NAME = "WebCore-LICENSE-LGPL-2.1.txt"
WEBCORE_LGPL21_SHA256 = "f2b3bd09663381deb99721109d22b47af1213bb43007a8b56a06c6375c8050ce"
WEBCORE_LGPL21_DESTINATION = (
    Path("Contents/Resources/NeAntikRuntimeLicenses") / WEBCORE_LGPL21_NAME
)
ANGLE_LICENSE_SOURCE = Path("docs/evidence/third-party/angle/ANGLE-LICENSE-43d5b8d85e2e5eed41d7ff8a79da831bf405be6c")
ANGLE_LICENSE_NAME = "ANGLE-LICENSE.txt"
ANGLE_LICENSE_SHA256 = "bf4da21bd20bcfb5b60b7ecc67fa864a79be049e21d6178076887f178dd6c71a"
ANGLE_LICENSE_DESTINATION = Path("Contents/Resources/NeAntikRuntimeLicenses") / ANGLE_LICENSE_NAME
XXHASH_LICENSE_SOURCE = Path("docs/evidence/third-party/angle/xxhash-LICENSE-e4c5da7234eca7baad9a46f0b144e49ccad2e500")
XXHASH_LICENSE_NAME = "xxHash-LICENSE.txt"
XXHASH_LICENSE_SHA256 = "6ffedbc0f7878612d2b23589f1ff2ab15633e1df7963a5d9fc750ec5500c7e7a"
XXHASH_LICENSE_DESTINATION = Path("Contents/Resources/NeAntikRuntimeLicenses") / XXHASH_LICENSE_NAME
CHROMIUM_ANGLE_LICENSE_SOURCE = Path("docs/evidence/third-party/chromium/LICENSE-738956cca47a264e92106fdbefdc040ee7ed487d")
CHROMIUM_ANGLE_LICENSE_NAME = "Chromium-ANGLE-DEPS-LICENSE.txt"
CHROMIUM_ANGLE_LICENSE_SHA256 = "368cca1106be99d39ecd32a38d8305585d802a475effb66380b91ffc9bcf709b"
CHROMIUM_ANGLE_LICENSE_DESTINATION = (
    Path("Contents/Resources/NeAntikRuntimeLicenses") / CHROMIUM_ANGLE_LICENSE_NAME
)
WEBRTC_CANDIDATE_ROOT = Path(
    "docs/evidence/third-party/webkit-v16-webrtc-notices-cmake-candidate-v2"
)
WEBRTC_MANIFEST_SOURCE = WEBRTC_CANDIDATE_ROOT / "MANIFEST.json"
WEBRTC_MANIFEST_SHA256 = "10ce49b7cc7cba3f78c04d4fc6231cb639734acf459e382be2481188ec1c9246"
WEBRTC_IMAGE_NAME = "libwebrtc.dylib"
WEBRTC_NOTICE_ROOT = Path("Contents/Resources/NeAntikRuntimeLicenses/WebRTC")
WEBRTC_SECTION_MARKER = "## Source-derived WebRTC notices: CMake libwebrtc.dylib"
WEBRTC_HTML_MARKER = '<section id="neantik-webrtc-cmake-runtime-notices">'
NOTICE_DESTINATION = Path("Contents/Resources/NeAntikRuntimeNotices.md")
HTML_DESTINATION = Path("Contents/Resources/NeAntikRuntimeCompliance/THIRD-PARTY-NOTICES.html")
SECTION_MARKER = "## Owned WebKit runtime component: CompatibilitySpan"
HTML_MARKER = '<section id="neantik-owned-webkit-compatibility-span">'
LGPL2_SECTION_MARKER = "## WebKit source-referenced license text: LGPL-2"
LGPL2_HTML_MARKER = '<section id="neantik-webcore-lgpl-2-license-text">'
LGPL21_SECTION_MARKER = "## WebKit source-referenced license text: LGPL-2.1"
LGPL21_HTML_MARKER = '<section id="neantik-webcore-lgpl-2-1-license-text">'
ANGLE_SECTION_MARKER = "## Source-mapped WebKit runtime notices: ANGLE"
ANGLE_HTML_MARKER = '<section id="neantik-angle-runtime-notices">'
WEBINSPECTOR_SECTION_MARKER = "## Bundled WebInspectorUI external license resources"
WEBINSPECTOR_HTML_MARKER = '<section id="neantik-webinspector-external-licenses">'
SANDBOX_SOURCE_ROOT = Path("docs/evidence/third-party/webkit-sandbox-source-v20")
SANDBOX_MANIFEST_SHA256 = "b59bd44c1f91dc8d7c17bb3afed8004e43c30ffeb37cfe627fc81bddf278d61d"
SANDBOX_NOTICE_ROOT = Path("Contents/Resources/NeAntikRuntimeLicenses/WebKitSandbox")
SANDBOX_SECTION_MARKER = "## Bundled WebKit sandbox source notices"
SANDBOX_HTML_MARKER = '<section id="neantik-webkit-sandbox-source-notices">'
SOURCE_CROSSWALK = Path("docs/evidence/webkit-v20-source-license-crosswalk-20261024.json")
SOURCE_CROSSWALK_SHA256 = "a4855fed2d0f33b31c791440538dbc481b0176665268e9dd57dbdbc9c23d9191"
SOURCE_CORPUS_ROOT = Path("docs/evidence/third-party/webkit-v20-license-text-corpus")
SOURCE_CORPUS_MANIFEST_SHA256 = "959dcc0612f01f3e420837bb917c77cdaa6b06f9d94a6cc6804362bbb9e6fb71"
SOURCE_CANDIDATE_COUNT = 12
SOURCE_CANDIDATE_NOTICE_ROOT = Path(
    "Contents/Resources/NeAntikRuntimeLicenses/WebKitSourceCandidates")
SOURCE_CANDIDATE_SECTION_MARKER = "## Pinned WebKit source license-text candidates"
SOURCE_CANDIDATE_HTML_MARKER = '<section id="neantik-webkit-source-license-candidates">'
# Source texts were matched byte-for-byte to these four framework resources in
# the pinned private v16 runtime. This is an inventory, not a terms decision.
WEBINSPECTOR_LICENSES = (
    ("CSSDocumentation", "b5179f780ec212a434efcc989a2295a140deb0bdb17182d2bf9c5f6f1f1a01c4", 1074),
    ("CodeMirror", "168a4becc968f5001e2ee2e0291b6e4daabafc1894a11ade1e11d56e96096e07", 1113),
    ("Esprima", "94bcb9959136723aa4fb36e1a6c4d5c662a2369978cfae344dabfb83ae619e79", 1303),
    ("three.js", "551f06ddc3dc36b56610aa23db680826ba9d9a02e8f89f7bec05d7fa27401a2b", 1081),
)
OWNED_MARKDOWN_MARKERS = (
    SECTION_MARKER, LGPL2_SECTION_MARKER, LGPL21_SECTION_MARKER,
    ANGLE_SECTION_MARKER, WEBRTC_SECTION_MARKER, WEBINSPECTOR_SECTION_MARKER,
    SANDBOX_SECTION_MARKER, SOURCE_CANDIDATE_SECTION_MARKER,
)
OWNED_HTML_MARKERS = (
    HTML_MARKER, LGPL2_HTML_MARKER, LGPL21_HTML_MARKER,
    ANGLE_HTML_MARKER, WEBRTC_HTML_MARKER, WEBINSPECTOR_HTML_MARKER,
    SANDBOX_HTML_MARKER, SOURCE_CANDIDATE_HTML_MARKER,
)
MACHO_MAGICS = {
    bytes.fromhex(value) for value in (
        "feedface", "cefaedfe", "feedfacf", "cffaedfe",
        "cafebabe", "bebafeca", "cafebabf", "bfbafeca",
    )
}


class NoticeError(RuntimeError):
    pass


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _physical_file(path: Path, *, label: str) -> None:
    if path.is_symlink() or not path.is_file():
        raise NoticeError(f"{label} must be a regular non-symlinked file")
    if not stat.S_ISREG(path.lstat().st_mode):
        raise NoticeError(f"{label} must be a regular file")


def _safe_destination(app: Path, relative: Path, *, create_parent: bool) -> Path:
    if app.is_symlink() or not app.is_dir():
        raise NoticeError("app bundle must be an existing physical directory")
    root = app.resolve(strict=True)
    destination = app / relative
    current = app
    for part in relative.parts[:-1]:
        current = current / part
        if current.exists() or current.is_symlink():
            if current.is_symlink() or not current.is_dir():
                raise NoticeError(f"unsafe non-directory path in app bundle: {relative}")
        elif create_parent:
            current.mkdir()
        else:
            raise NoticeError(f"required app resource directory is missing: {relative.parent}")
        try:
            current.resolve(strict=True).relative_to(root)
        except (OSError, ValueError) as error:
            raise NoticeError(f"app resource path escapes bundle: {relative}") from error
    if destination.is_symlink():
        raise NoticeError(f"app resource must not be a symlink: {relative}")
    if destination.exists() and not destination.is_file():
        raise NoticeError(f"app resource must be a regular file: {relative}")
    return destination


def _compatibility_span(runtime_frameworks: Path) -> Path:
    if runtime_frameworks.is_symlink() or not runtime_frameworks.is_dir():
        raise NoticeError("WebKit Frameworks input must be a physical directory")
    candidates = []
    for candidate in runtime_frameworks.rglob("libswiftCompatibilitySpan.dylib"):
        if candidate.is_symlink():
            raise NoticeError("CompatibilitySpan runtime image must not be a symlink")
        if candidate.is_file():
            candidates.append(candidate)
    if len(candidates) != 1:
        raise NoticeError("expected exactly one bundled libswiftCompatibilitySpan.dylib")
    library = candidates[0]
    _physical_file(library, label="CompatibilitySpan runtime image")
    with library.open("rb") as stream:
        if stream.read(4) not in MACHO_MAGICS:
            raise NoticeError("CompatibilitySpan runtime image is not a Mach-O file")
    return library


def _angle_library(runtime_frameworks: Path) -> Path:
    if runtime_frameworks.is_symlink() or not runtime_frameworks.is_dir():
        raise NoticeError("WebKit Frameworks input must be a physical directory")
    candidates = list(runtime_frameworks.rglob("libANGLE-shared.dylib"))
    if any(candidate.is_symlink() for candidate in candidates):
        raise NoticeError("ANGLE runtime image must not be a symlink")
    candidates = [candidate for candidate in candidates if candidate.is_file()]
    if len(candidates) != 1:
        raise NoticeError("expected exactly one bundled libANGLE-shared.dylib")
    library = candidates[0]
    _physical_file(library, label="ANGLE runtime image")
    with library.open("rb") as stream:
        if stream.read(4) not in MACHO_MAGICS:
            raise NoticeError("ANGLE runtime image is not a Mach-O file")
    return library


def _webrtc_library(runtime_frameworks: Path) -> Path:
    if runtime_frameworks.is_symlink() or not runtime_frameworks.is_dir():
        raise NoticeError("WebKit Frameworks input must be a physical directory")
    candidates = list(runtime_frameworks.rglob(WEBRTC_IMAGE_NAME))
    if any(candidate.is_symlink() for candidate in candidates):
        raise NoticeError("WebRTC runtime image must not be a symlink")
    candidates = [candidate for candidate in candidates if candidate.is_file()]
    if len(candidates) != 1:
        raise NoticeError("expected exactly one bundled libwebrtc.dylib")
    library = candidates[0]
    _physical_file(library, label="WebRTC runtime image")
    with library.open("rb") as stream:
        if stream.read(4) not in MACHO_MAGICS:
            raise NoticeError("WebRTC runtime image is not a Mach-O file")
    return library


def _safe_manifest_relative(value: object, *, field: str) -> Path:
    if not isinstance(value, str) or "\\" in value:
        raise NoticeError(f"WebRTC manifest {field} is not a safe relative path")
    posix = PurePosixPath(value)
    if posix.is_absolute() or not posix.parts or any(part in ("", ".", "..") for part in posix.parts):
        raise NoticeError(f"WebRTC manifest {field} is not a safe relative path")
    return Path(*posix.parts)


def _physical_path_beneath(root: Path, relative: Path, *, label: str) -> Path:
    current = root
    for part in relative.parts:
        current = current / part
        if current.is_symlink():
            raise NoticeError(f"{label} must not traverse a symlink")
    _physical_file(current, label=label)
    try:
        current.resolve(strict=True).relative_to(root.resolve(strict=True))
    except (OSError, ValueError) as error:
        raise NoticeError(f"{label} escapes its pinned root") from error
    return current


def _remove_owned_markdown_sections(text: str) -> str:
    """Remove only prior generated WebKit H2 sections; refuse duplicate markers."""
    lines = text.splitlines(keepends=True)
    result: list[str] = []
    index = 0
    while index < len(lines):
        heading = lines[index].rstrip("\r\n")
        if heading not in OWNED_MARKDOWN_MARKERS:
            result.append(lines[index])
            index += 1
            continue
        if sum(line.rstrip("\r\n") == heading for line in lines) != 1:
            raise NoticeError(f"duplicate owned-WebKit Markdown marker: {heading}")
        index += 1
        while index < len(lines) and not lines[index].startswith("## "):
            index += 1
    return "".join(result).rstrip() + "\n"


def _remove_owned_html_sections(text: str) -> str:
    """Remove prior generated HTML sections by unique section ID."""
    for marker in OWNED_HTML_MARKERS:
        count = text.count(marker)
        if count > 1:
            raise NoticeError(f"duplicate owned-WebKit HTML marker: {marker}")
        if count == 1:
            start = text.index(marker)
            end = text.find("</section>", start + len(marker))
            if end < 0:
                raise NoticeError(f"unterminated owned-WebKit HTML section: {marker}")
            end += len("</section>")
            if text[end:end + 1] == "\n":
                end += 1
            text = text[:start] + text[end:]
    return text


def _webrtc_notice_sources(project_root: Path) -> tuple[dict, tuple[tuple[Path, Path, str, int], ...]]:
    manifest_path = project_root / WEBRTC_MANIFEST_SOURCE
    _physical_file(manifest_path, label="pinned WebRTC candidate manifest")
    manifest_bytes = manifest_path.read_bytes()
    if hashlib.sha256(manifest_bytes).hexdigest() != WEBRTC_MANIFEST_SHA256:
        raise NoticeError("pinned WebRTC candidate manifest SHA-256 mismatch")
    try:
        manifest = json.loads(manifest_bytes)
    except (UnicodeDecodeError, ValueError) as error:
        raise NoticeError("pinned WebRTC candidate manifest is invalid JSON") from error
    if (manifest.get("schemaVersion") != 1
            or manifest.get("upstream", {}).get("commit") != "43d5b8d85e2e5eed41d7ff8a79da831bf405be6c"
            or manifest.get("status") != "research candidate; not a complete notice bundle, legal opinion, or redistribution approval"
            or manifest.get("buildScope") != "pinned CMake libwebrtc.dylib link/source receipts; includes mapped direct-source notices and selected static-archive notices"):
        raise NoticeError("pinned WebRTC candidate manifest scope or provenance mismatch")
    notices = manifest.get("notices")
    if not isinstance(notices, list) or manifest.get("noticeCount") != 36 or len(notices) != 36:
        raise NoticeError("pinned WebRTC notice count mismatch")
    candidate_root = project_root / WEBRTC_CANDIDATE_ROOT
    if candidate_root.is_symlink() or not candidate_root.is_dir():
        raise NoticeError("pinned WebRTC candidate root must be a physical directory")
    result = []
    seen_sources: set[Path] = set()
    seen_outputs: set[Path] = set()
    for entry in notices:
        if not isinstance(entry, dict):
            raise NoticeError("pinned WebRTC notice entry is invalid")
        source_relative = _safe_manifest_relative(entry.get("sourcePath"), field="sourcePath")
        output_relative = _safe_manifest_relative(entry.get("outputPath"), field="outputPath")
        if output_relative != Path("files") / source_relative:
            raise NoticeError("pinned WebRTC output path does not preserve source attribution")
        if source_relative in seen_sources or output_relative in seen_outputs:
            raise NoticeError("pinned WebRTC manifest contains duplicate paths")
        seen_sources.add(source_relative)
        seen_outputs.add(output_relative)
        digest = entry.get("sha256")
        size = entry.get("bytes")
        if (not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest)
                or type(size) is not int or size < 0):
            raise NoticeError("pinned WebRTC notice hash or byte count is invalid")
        source = _physical_path_beneath(
            candidate_root, output_relative, label=f"pinned WebRTC notice {source_relative}")
        if source.stat().st_size != size or sha256_file(source) != digest:
            raise NoticeError(f"pinned WebRTC notice source hash/size mismatch: {source_relative}")
        result.append((source_relative, output_relative, digest, size))
    return manifest, tuple(result)


def _license(project_root: Path) -> Path:
    source = project_root / LICENSE_SOURCE
    _physical_file(source, label="canonical Swift runtime license")
    if sha256_file(source) != LICENSE_SHA256:
        raise NoticeError("canonical Swift runtime license SHA-256 mismatch")
    return source


def _webcore_lgpl2_license(project_root: Path) -> Path:
    source = project_root / WEBCORE_LGPL2_SOURCE
    _physical_file(source, label="pinned WebCore LGPL-2 license text")
    if sha256_file(source) != WEBCORE_LGPL2_SHA256:
        raise NoticeError("pinned WebCore LGPL-2 license SHA-256 mismatch")
    return source


def _webcore_lgpl21_license(project_root: Path) -> Path:
    source = project_root / WEBCORE_LGPL21_SOURCE
    _physical_file(source, label="pinned WebCore LGPL-2.1 license text")
    if sha256_file(source) != WEBCORE_LGPL21_SHA256:
        raise NoticeError("pinned WebCore LGPL-2.1 license SHA-256 mismatch")
    return source


def _angle_notice_sources(project_root: Path) -> tuple[tuple[Path, str, str, Path], ...]:
    sources = (
        (ANGLE_LICENSE_SOURCE, ANGLE_LICENSE_NAME, ANGLE_LICENSE_SHA256,
         ANGLE_LICENSE_DESTINATION),
        (XXHASH_LICENSE_SOURCE, XXHASH_LICENSE_NAME, XXHASH_LICENSE_SHA256,
         XXHASH_LICENSE_DESTINATION),
        (CHROMIUM_ANGLE_LICENSE_SOURCE, CHROMIUM_ANGLE_LICENSE_NAME,
         CHROMIUM_ANGLE_LICENSE_SHA256, CHROMIUM_ANGLE_LICENSE_DESTINATION),
    )
    for relative, _name, expected_hash, _destination in sources:
        source = project_root / relative
        _physical_file(source, label=f"pinned WebKit license text: {relative}")
        if sha256_file(source) != expected_hash:
            raise NoticeError(f"pinned WebKit license SHA-256 mismatch: {relative}")
    return sources


def _webinspector_notice_sources(project_root: Path, runtime_frameworks: Path | None) -> None:
    for name, digest, size in WEBINSPECTOR_LICENSES:
        source_relative = Path("docs/evidence/third-party/webinspector") / name / "LICENSE"
        source = _physical_path_beneath(project_root, source_relative,
                                        label=f"pinned WebInspectorUI source license {name}")
        if source.stat().st_size != size or sha256_file(source) != digest:
            raise NoticeError(f"pinned WebInspectorUI source license hash/size mismatch: {name}")
        if runtime_frameworks is not None:
            bundled_relative = (Path("WebInspectorUI.framework/Versions/A/Resources/External")
                                / name / "LICENSE")
            bundled = _physical_path_beneath(runtime_frameworks, bundled_relative,
                                             label=f"bundled WebInspectorUI license {name}")
            if bundled.stat().st_size != size or sha256_file(bundled) != digest:
                raise NoticeError(f"bundled WebInspectorUI license hash/size mismatch: {name}")


def render_webinspector_markdown() -> str:
    lines = [WEBINSPECTOR_SECTION_MARKER, "",
             "These four external license texts are included in the pinned WebInspectorUI framework resources.",
             "Each source path and bundled path below has identical hash-pinned bytes.", ""]
    for name, digest, _size in WEBINSPECTOR_LICENSES:
        lines.append(f"- `{name}`: upstream `Source/WebInspectorUI/UserInterface/External/{name}/LICENSE`; "
                     f"bundled `WebInspectorUI.framework/Versions/A/Resources/External/{name}/LICENSE`; "
                     f"SHA-256 `{digest}`.")
    lines.extend(["", "This is a factual resource index. Governing terms, complete notice coverage, "
                  "and redistribution review remain open."])
    return "\n".join(lines) + "\n"


def render_webinspector_html() -> str:
    rows = "\n".join(
        "<tr><td><code>" + html.escape(name) + "</code></td><td><code>" +
        html.escape(f"Source/WebInspectorUI/UserInterface/External/{name}/LICENSE") +
        "</code></td><td><code>" +
        html.escape(f"WebInspectorUI.framework/Versions/A/Resources/External/{name}/LICENSE") +
        f"</code></td><td><code>{digest}</code></td></tr>"
        for name, digest, _size in WEBINSPECTOR_LICENSES
    )
    return (f"{WEBINSPECTOR_HTML_MARKER}\n"
            "<h2>Bundled WebInspectorUI external license resources</h2>\n"
            "<p>Four source texts match the pinned framework resources by path and hash.</p>\n"
            "<table><thead><tr><th>Component</th><th>Upstream path</th>"
            "<th>Bundled path</th><th>SHA-256</th></tr></thead><tbody>\n"
            f"{rows}\n</tbody></table>\n"
            "<p>This resource index does not establish governing terms, complete "
            "notice coverage, or redistribution approval.</p>\n</section>")


def _sandbox_notice_sources(project_root: Path) -> tuple[tuple[str, str, str, int], ...]:
    manifest_path = _physical_path_beneath(
        project_root, SANDBOX_SOURCE_ROOT / "MANIFEST.json",
        label="pinned WebKit sandbox notice manifest")
    if sha256_file(manifest_path) != SANDBOX_MANIFEST_SHA256:
        raise NoticeError("pinned WebKit sandbox notice manifest SHA-256 mismatch")
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (ValueError, UnicodeError) as error:
        raise NoticeError("invalid WebKit sandbox notice manifest") from error
    if not isinstance(manifest, dict):
        raise NoticeError("invalid WebKit sandbox notice manifest")
    rows = manifest.get("rows")
    if (manifest.get("schemaVersion") != 1
            or manifest.get("pinnedWebKitCommit") != "43d5b8d85e2e5eed41d7ff8a79da831bf405be6c"
            or manifest.get("patchedSources") != [{
                "sourcePath": "Source/WebKit/WebProcess/com.apple.WebProcess.sb.in",
                "patchSHA256": "b33b9320bd8f3bae56eadebc738fe91d40f0cf77e89fd2885bf28679d2af0735",
            }]
            or not isinstance(rows, list) or len(rows) != 6):
        raise NoticeError("invalid WebKit sandbox notice manifest")
    result = []
    seen = set()
    for row in rows:
        if not isinstance(row, dict) or set(row) != {"sourcePath", "copiedPath", "runtimePath", "sha256", "bytes"}:
            raise NoticeError("invalid WebKit sandbox notice row")
        name, source_path, runtime_path = (row[key] for key in
                                           ("copiedPath", "sourcePath", "runtimePath"))
        if (not isinstance(name, str) or not re.fullmatch(r"[A-Za-z0-9.-]+", name)
                or name in seen or not isinstance(source_path, str)
                or not source_path.startswith("Source/")
                or not isinstance(runtime_path, str)
                or not runtime_path.endswith(".sb")
                or not isinstance(row["sha256"], str)
                or not re.fullmatch(r"[0-9a-f]{64}", row["sha256"])
                or type(row["bytes"]) is not int or row["bytes"] <= 0):
            raise NoticeError("invalid WebKit sandbox notice row")
        seen.add(name)
        source = _physical_path_beneath(
            project_root, SANDBOX_SOURCE_ROOT / name,
            label=f"pinned WebKit sandbox source {name}")
        if source.stat().st_size != row["bytes"] or sha256_file(source) != row["sha256"]:
            raise NoticeError(f"pinned WebKit sandbox source hash/size mismatch: {name}")
        result.append((name, source_path, runtime_path, row["bytes"]))
    return tuple(result)


def _source_candidate_notice_sources(
    project_root: Path,
) -> tuple[dict, bytes, tuple[tuple[str, Path, str, int], ...]]:
    """Return exact license-text candidates whose source paths occur in build maps.

    The path association is technical evidence only. It intentionally does not
    decide which terms govern any binary or replace the source headers.
    """
    crosswalk_path = _physical_path_beneath(
        project_root, SOURCE_CROSSWALK, label="pinned WebKit source/license crosswalk")
    if sha256_file(crosswalk_path) != SOURCE_CROSSWALK_SHA256:
        raise NoticeError("pinned WebKit source/license crosswalk SHA-256 mismatch")
    corpus_manifest_path = _physical_path_beneath(
        project_root, SOURCE_CORPUS_ROOT / "MANIFEST.json",
        label="pinned WebKit source license-text corpus manifest")
    if sha256_file(corpus_manifest_path) != SOURCE_CORPUS_MANIFEST_SHA256:
        raise NoticeError("pinned WebKit source license-text corpus manifest SHA-256 mismatch")
    try:
        crosswalk = json.loads(crosswalk_path.read_text(encoding="utf-8"))
        corpus = json.loads(corpus_manifest_path.read_text(encoding="utf-8"))
    except (ValueError, UnicodeError) as error:
        raise NoticeError("pinned WebKit source/license crosswalk is invalid") from error
    commit = "43d5b8d85e2e5eed41d7ff8a79da831bf405be6c"
    if (crosswalk.get("schemaVersion") != 1
            or crosswalk.get("status") != "technical-source-license-crosswalk;not-legal-applicability-or-release-approval"
            or crosswalk.get("upstream", {}).get("commit") != commit
            or crosswalk.get("candidateLicenseCorpus", {}).get("count") != 308
            or corpus.get("schemaVersion") != 1 or corpus.get("commit") != commit
            or corpus.get("sourcePatchSHA256") != "b33b9320bd8f3bae56eadebc738fe91d40f0cf77e89fd2885bf28679d2af0735"
            or not isinstance(corpus.get("entries"), list)
            or len(corpus["entries"]) != 308):
        raise NoticeError("pinned WebKit source/license manifests have an unexpected scope")

    selected: set[str] = set()
    for section, row_key in (("directCompileInputs", "sourceRows"),
                             ("webCoreUnityInputs", "sourceRows")):
        rows = crosswalk.get(section, {}).get(row_key)
        if not isinstance(rows, list):
            raise NoticeError("WebKit source/license crosswalk source rows are missing")
        for row in rows:
            candidates = row.get("ancestorLicenseTextCandidates") if isinstance(row, dict) else None
            if not isinstance(candidates, list):
                raise NoticeError("WebKit source/license crosswalk candidate list is invalid")
            selected.update(candidates)
    resources = crosswalk.get("runtimeResources", {}).get("sourceRows")
    if not isinstance(resources, list):
        raise NoticeError("WebKit source/license crosswalk resource rows are missing")
    for row in resources:
        mapped = row.get("mappedSources") if isinstance(row, dict) else None
        if not isinstance(mapped, list):
            raise NoticeError("WebKit source/license crosswalk mapped-source list is invalid")
        for source in mapped:
            candidates = source.get("ancestorLicenseTextCandidates") if isinstance(source, dict) else None
            if not isinstance(candidates, list):
                raise NoticeError("WebKit resource license candidate list is invalid")
            selected.update(candidates)
    if len(selected) != SOURCE_CANDIDATE_COUNT:
        raise NoticeError("WebKit source/license candidate set differs from the pinned crosswalk")

    entries = corpus["entries"]
    by_source = {row.get("sourcePath"): row for row in entries if isinstance(row, dict)}
    if len(by_source) != len(entries):
        raise NoticeError("WebKit source license corpus has duplicate paths")
    packed = []
    copied = []
    for source_path in sorted(selected):
        row = by_source.get(source_path)
        if not isinstance(row, dict):
            raise NoticeError(f"WebKit candidate license text is missing from corpus: {source_path}")
        relative = row.get("corpusPath")
        if (not isinstance(source_path, str) or not source_path.startswith("Source/")
                or not isinstance(relative, str) or "\\" in relative
                or Path(relative).is_absolute() or ".." in Path(relative).parts
                or not isinstance(row.get("sha256"), str)
                or not re.fullmatch(r"[0-9a-f]{64}", row["sha256"])
                or type(row.get("bytes")) is not int or row["bytes"] <= 0):
            raise NoticeError("WebKit source license corpus entry is malformed")
        source = _physical_path_beneath(
            project_root / SOURCE_CORPUS_ROOT, Path(relative),
            label=f"pinned WebKit source license candidate {source_path}")
        if source.stat().st_size != row["bytes"] or sha256_file(source) != row["sha256"]:
            raise NoticeError(f"WebKit source license candidate hash/size mismatch: {source_path}")
        output = Path("files") / source_path
        packed.append({"sourcePath": source_path, "outputPath": output.as_posix(),
                       "sha256": row["sha256"], "bytes": row["bytes"]})
        copied.append((source_path, source, row["sha256"], row["bytes"]))
    manifest = {
        "schemaVersion": 1,
        "status": "technical source-path candidates; not a legal applicability decision",
        "upstreamCommit": commit,
        "sourcePatchSHA256": crosswalk["upstream"]["sourcePatchSHA256"],
        "crosswalkSHA256": SOURCE_CROSSWALK_SHA256,
        "corpusManifestSHA256": SOURCE_CORPUS_MANIFEST_SHA256,
        "entryCount": len(packed),
        "entries": packed,
    }
    manifest_bytes = (json.dumps(manifest, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
    return manifest, manifest_bytes, tuple(copied)


def render_source_candidate_markdown(manifest: dict) -> str:
    lines = [SOURCE_CANDIDATE_SECTION_MARKER, "",
             "These exact license/copying/patent texts are path-associated candidates from the pinned WebKit source maps. They are included with the app and corresponding-source materials to avoid dropping a discovered text.",
             "Path association is not a decision that every candidate governs the shipped binary; source headers and the corresponding-source offer remain authoritative.", ""]
    for row in manifest["entries"]:
        lines.append(f"- `{row['sourcePath']}` → `NeAntikRuntimeLicenses/WebKitSourceCandidates/{row['outputPath']}`; {row['bytes']} bytes; SHA-256 `{row['sha256']}`.")
    lines.extend(["", "This inventory is not a legal opinion or a claim that source/license review is complete."])
    return "\n".join(lines) + "\n"


def render_source_candidate_html(manifest: dict) -> str:
    rows = "\n".join(
        "<tr><td><code>" + html.escape(row["sourcePath"]) + "</code></td><td><code>" +
        html.escape("NeAntikRuntimeLicenses/WebKitSourceCandidates/" + row["outputPath"]) +
        f"</code></td><td>{row['bytes']}</td><td><code>{row['sha256']}</code></td></tr>"
        for row in manifest["entries"])
    return (f"{SOURCE_CANDIDATE_HTML_MARKER}\n<h2>Pinned WebKit source license-text candidates</h2>\n"
            "<p>These exact texts are associated by source path with the pinned build maps and are included for transparency. That association is not a legal applicability decision.</p>\n"
            "<table><thead><tr><th>Pinned source path</th><th>Packaged text</th><th>Bytes</th><th>SHA-256</th></tr></thead><tbody>\n"
            f"{rows}\n</tbody></table>\n"
            "<p>This inventory is not a legal opinion or a claim that source/license review is complete.</p>\n</section>")


def render_sandbox_markdown(rows: tuple[tuple[str, str, str, int], ...]) -> str:
    lines = [SANDBOX_SECTION_MARKER, "",
             "Six exact source files for bundled sandbox resources are copied under "
             "`NeAntikRuntimeLicenses/WebKitSandbox/`. Their copyright and "
             "redistribution conditions are retained in those files.", ""]
    for name, source_path, runtime_path, _size in rows:
        lines.append(f"- `{runtime_path}`: source `{source_path}`; "
                     f"copy `NeAntikRuntimeLicenses/WebKitSandbox/{name}`.")
    lines.extend(["", "This is a source-and-notice byte binding, not a determination "
                  "of every linked image's terms or final redistribution approval."])
    return "\n".join(lines) + "\n"


def render_sandbox_html(rows: tuple[tuple[str, str, str, int], ...]) -> str:
    table = "\n".join(
        "<tr><td><code>" + html.escape(runtime_path) + "</code></td><td><code>" +
        html.escape(source_path) + "</code></td><td><code>" +
        html.escape(f"NeAntikRuntimeLicenses/WebKitSandbox/{name}") + "</code></td></tr>"
        for name, source_path, runtime_path, _size in rows)
    return (f"{SANDBOX_HTML_MARKER}\n"
            "<h2>Bundled WebKit sandbox source notices</h2>\n"
            "<p>Six exact source files for bundled sandbox resources retain "
            "their copyright and redistribution conditions.</p>\n"
            "<table><thead><tr><th>Runtime resource</th><th>Source</th>"
            "<th>Packaged copy</th></tr></thead><tbody>\n"
            f"{table}\n</tbody></table>\n"
            "<p>This source-and-notice binding is not a determination of all "
            "linked-image terms or final redistribution approval.</p>\n</section>")


def _atomic_write(path: Path, data: bytes, *, mode: int | None = None) -> None:
    previous_mode = stat.S_IMODE(path.stat().st_mode) if path.exists() else 0o644
    file_mode = previous_mode if mode is None else mode
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            os.fchmod(stream.fileno(), file_mode)
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def _compliance_manifest(app: Path, current_html: bytes) -> tuple[Path, dict] | None:
    path = app / "Contents/Resources/NeAntikRuntimeCompliance/compliance-manifest.json"
    if not path.exists() and not path.is_symlink():
        return None
    _physical_file(path, label="Chromium compliance manifest")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise NoticeError("Chromium compliance manifest is unreadable") from error
    notices = value.get("notices") if isinstance(value, dict) else None
    if (not isinstance(value, dict) or value.get("schemaVersion") != 1
            or not isinstance(notices, dict)
            or notices.get("file") != HTML_DESTINATION.name
            or notices.get("sha256") != hashlib.sha256(current_html).hexdigest()):
        raise NoticeError("Chromium compliance manifest does not bind the current notice bytes")
    return path, value


def _refresh_compliance_notice_hash(manifest: tuple[Path, dict] | None, final_html: bytes) -> None:
    if manifest is None:
        return
    path, value = manifest
    value["notices"]["sha256"] = hashlib.sha256(final_html).hexdigest()
    payload = (json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + "\n").encode("utf-8")
    _atomic_write(path, payload)


def render_markdown(library_sha256: str) -> str:
    return (
        f"{SECTION_MARKER}\n\n"
        "The bundled owned-WebKit runtime includes `libswiftCompatibilitySpan.dylib`.\n\n"
        f"- Runtime image SHA-256: `{library_sha256}`\n"
        f"- Applicable license text: `NeAntikRuntimeLicenses/{LICENSE_NAME}`\n"
        f"- License SHA-256: `{LICENSE_SHA256}`\n\n"
        "This entry applies only to the named Swift compatibility library. It does not\n"
        "close the separate source, notices, or relinking review for WebKit, WebCore,\n"
        "JavaScriptCore, or other bundled components. Those release gates remain open.\n"
    )


def render_html(library_sha256: str) -> str:
    escaped_name = html.escape(LICENSE_NAME)
    return (
        f'{HTML_MARKER}\n'
        "<h2>Owned WebKit runtime component: CompatibilitySpan</h2>\n"
        "<p>The bundled owned-WebKit runtime includes "
        "<code>libswiftCompatibilitySpan.dylib</code>.</p>\n"
        f"<ul><li>Runtime image SHA-256: <code>{library_sha256}</code></li>\n"
        f"<li>Applicable license text: <code>NeAntikRuntimeLicenses/{escaped_name}</code></li>\n"
        f"<li>License SHA-256: <code>{LICENSE_SHA256}</code></li></ul>\n"
        "<p>This entry applies only to the named Swift compatibility library. "
        "Separate source, notices, and relinking review for WebKit, WebCore, "
        "JavaScriptCore, and other bundled components remains open.</p>\n"
        "</section>"
    )


def render_lgpl2_markdown() -> str:
    return (
        f"{LGPL2_SECTION_MARKER}\n\n"
        "The exact pinned WebCore `LICENSE-LGPL-2` text is included at "
        f"`NeAntikRuntimeLicenses/{WEBCORE_LGPL2_NAME}`.\n\n"
        f"- License text SHA-256: `{WEBCORE_LGPL2_SHA256}`\n\n"
        "This is a source-referenced license-text notice, not a determination "
        "that every WebKit file or shipped binary is governed by these terms. "
        "Per-file scope, corresponding source, relinking, and distribution "
        "requirements remain under review.\n"
    )


def render_lgpl2_html() -> str:
    return (
        f'{LGPL2_HTML_MARKER}\n'
        "<h2>WebKit source-referenced license text: LGPL-2</h2>\n"
        "<p>The exact pinned WebCore <code>LICENSE-LGPL-2</code> text is "
        f"included at <code>NeAntikRuntimeLicenses/{html.escape(WEBCORE_LGPL2_NAME)}</code>.</p>\n"
        f"<p>License text SHA-256: <code>{WEBCORE_LGPL2_SHA256}</code></p>\n"
        "<p>This notice does not determine that every WebKit file or shipped "
        "binary is governed by these terms. Per-file scope, corresponding "
        "source, relinking, and distribution requirements remain under review.</p>\n"
        "</section>"
    )


def render_lgpl21_markdown() -> str:
    return (
        f"{LGPL21_SECTION_MARKER}\n\n"
        "The exact pinned WebCore `LICENSE-LGPL-2.1` text is included at "
        f"`NeAntikRuntimeLicenses/{WEBCORE_LGPL21_NAME}`.\n\n"
        f"- License text SHA-256: `{WEBCORE_LGPL21_SHA256}`\n\n"
        "This records source text, not a per-file or per-image license determination. "
        "Applicability, corresponding source, relinking, and distribution remain under review.\n"
    )


def render_lgpl21_html() -> str:
    return (
        f'{LGPL21_HTML_MARKER}\n'
        "<h2>WebKit source-referenced license text: LGPL-2.1</h2>\n"
        "<p>The exact pinned WebCore <code>LICENSE-LGPL-2.1</code> text is "
        f"included at <code>NeAntikRuntimeLicenses/{html.escape(WEBCORE_LGPL21_NAME)}</code>.</p>\n"
        f"<p>License text SHA-256: <code>{WEBCORE_LGPL21_SHA256}</code></p>\n"
        "<p>This records source text, not a per-file or per-image license "
        "determination. Applicability, corresponding source, relinking, and "
        "distribution remain under review.</p>\n</section>"
    )


def render_angle_markdown(library_sha256: str) -> str:
    return (
        f"{ANGLE_SECTION_MARKER}\n\n"
        "The bundled owned-WebKit runtime includes `libANGLE-shared.dylib`. "
        "The exact candidate image retains xxHash and ANGLE zlib compression helper symbols.\n\n"
        f"- Runtime image SHA-256: `{library_sha256}`\n"
        f"- ANGLE license: `NeAntikRuntimeLicenses/{ANGLE_LICENSE_NAME}` "
        f"(SHA-256 `{ANGLE_LICENSE_SHA256}`)\n"
        f"- xxHash license: `NeAntikRuntimeLicenses/{XXHASH_LICENSE_NAME}` "
        f"(SHA-256 `{XXHASH_LICENSE_SHA256}`)\n"
        f"- Chromium DEPS license: `NeAntikRuntimeLicenses/{CHROMIUM_ANGLE_LICENSE_NAME}` "
        f"(SHA-256 `{CHROMIUM_ANGLE_LICENSE_SHA256}`)\n\n"
        "These notices follow the pinned CMake/link map and retained image symbols. "
        "They do not establish complete notice coverage for every image/resource "
        "or provide a legal conclusion.\n"
    )


def render_angle_html(library_sha256: str) -> str:
    return (
        f'{ANGLE_HTML_MARKER}\n'
        "<h2>Source-mapped WebKit runtime notices: ANGLE</h2>\n"
        "<p>The bundled owned-WebKit runtime includes "
        "<code>libANGLE-shared.dylib</code>. The exact candidate image retains "
        "xxHash and ANGLE zlib compression helper symbols.</p>\n"
        f"<ul><li>Runtime image SHA-256: <code>{library_sha256}</code></li>\n"
        f"<li>ANGLE license: <code>NeAntikRuntimeLicenses/{html.escape(ANGLE_LICENSE_NAME)}</code> "
        f"(SHA-256 <code>{ANGLE_LICENSE_SHA256}</code>)</li>\n"
        f"<li>xxHash license: <code>NeAntikRuntimeLicenses/{html.escape(XXHASH_LICENSE_NAME)}</code> "
        f"(SHA-256 <code>{XXHASH_LICENSE_SHA256}</code>)</li>\n"
        f"<li>Chromium DEPS license: <code>NeAntikRuntimeLicenses/{html.escape(CHROMIUM_ANGLE_LICENSE_NAME)}</code> "
        f"(SHA-256 <code>{CHROMIUM_ANGLE_LICENSE_SHA256}</code>)</li></ul>\n"
        "<p>These notices follow the pinned CMake/link map and retained image "
        "symbols. Completeness for all images/resources and legal applicability "
        "remain under review.</p>\n</section>"
    )


def render_webrtc_markdown(library_sha256: str, manifest: dict,
                           notices: tuple[tuple[Path, Path, str, int], ...]) -> str:
    lines = [
        f"{WEBRTC_SECTION_MARKER}", "",
        "This source-derived candidate covers the pinned CMake `libwebrtc.dylib` link/source receipts only.", "",
        f"- Runtime image SHA-256: `{library_sha256}`",
        f"- Upstream WebKit commit: `{manifest['upstream']['commit']}`",
        f"- Candidate manifest: `NeAntikRuntimeLicenses/WebRTC/MANIFEST.json` "
        f"(SHA-256 `{WEBRTC_MANIFEST_SHA256}`)",
        f"- Source notice files: {len(notices)}", "",
        "The source-derived mapping is not a complete runtime notice bundle, legal opinion, or redistribution approval. "
        "WebCore/PAL/ANGLE/resources, source and relinking duties, and qualified review remain separate release gates.", "",
        "| Pinned source path | SHA-256 |", "| --- | --- |",
    ]
    lines.extend(f"| `{source}` | `{digest}` |" for source, _output, digest, _size in notices)
    return "\n".join(lines) + "\n"


def render_webrtc_html(library_sha256: str, manifest: dict,
                       notices: tuple[tuple[Path, Path, str, int], ...]) -> str:
    rows = "\n".join(
        f"<tr><td><code>{html.escape(source.as_posix())}</code></td>"
        f"<td><code>{digest}</code></td></tr>"
        for source, _output, digest, _size in notices
    )
    return (
        f'{WEBRTC_HTML_MARKER}\n<h2>Source-derived WebRTC notices: CMake libwebrtc.dylib</h2>\n'
        "<p>This source-derived candidate covers the pinned CMake link/source receipts only.</p>\n"
        f"<p>Runtime image SHA-256: <code>{library_sha256}</code><br>"
        f"Upstream WebKit commit: <code>{html.escape(manifest['upstream']['commit'])}</code><br>"
        f"Candidate manifest: <code>NeAntikRuntimeLicenses/WebRTC/MANIFEST.json</code> "
        f"(SHA-256 <code>{WEBRTC_MANIFEST_SHA256}</code>)<br>Source notice files: {len(notices)}</p>\n"
        "<p>This is not a complete runtime notice bundle, legal opinion, or redistribution approval. "
        "Other runtime images/resources, source and relinking duties, and qualified review remain open.</p>\n"
        f"<table><thead><tr><th>Pinned source path</th><th>SHA-256</th></tr></thead>"
        f"<tbody>{rows}</tbody></table>\n</section>"
    )


def preflight_owned_webkit_notices(
    app: Path, runtime_frameworks: Path, *, project_root: Path = PROJECT_ROOT,
) -> None:
    """Validate notice inputs in a disposable app before changing the signed app."""
    with tempfile.TemporaryDirectory(prefix="neantik-webkit-notice-preflight-") as temporary:
        scratch = Path(temporary) / "NeAntik.app"
        for relative in (NOTICE_DESTINATION, HTML_DESTINATION):
            source = _safe_destination(app, relative, create_parent=False)
            _physical_file(source, label=f"app notice {relative}")
            destination = scratch / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, destination)
        install_owned_webkit_notices(scratch, runtime_frameworks, project_root=project_root)


def install_owned_webkit_notices(
    app: Path, runtime_frameworks: Path, *, project_root: Path = PROJECT_ROOT,
) -> dict[str, str]:
    """Copy hash-pinned license texts and add scoped Markdown/HTML notices."""
    source_license = _license(project_root)
    source_lgpl2 = _webcore_lgpl2_license(project_root)
    source_lgpl21 = _webcore_lgpl21_license(project_root)
    angle_notice_sources = _angle_notice_sources(project_root)
    webrtc_manifest, webrtc_notices = _webrtc_notice_sources(project_root)
    _webinspector_notice_sources(project_root, runtime_frameworks)
    sandbox_rows = _sandbox_notice_sources(project_root)
    source_candidate_manifest, source_candidate_manifest_bytes, source_candidate_sources = (
        _source_candidate_notice_sources(project_root))
    library = _compatibility_span(runtime_frameworks)
    library_hash = sha256_file(library)
    angle_library = _angle_library(runtime_frameworks)
    angle_hash = sha256_file(angle_library)
    webrtc_library = _webrtc_library(runtime_frameworks)
    webrtc_hash = sha256_file(webrtc_library)
    markdown = _safe_destination(app, NOTICE_DESTINATION, create_parent=False)
    html_notice = _safe_destination(app, HTML_DESTINATION, create_parent=False)
    packaged_license = _safe_destination(app, LICENSE_DESTINATION, create_parent=True)
    packaged_lgpl2 = _safe_destination(app, WEBCORE_LGPL2_DESTINATION, create_parent=True)
    packaged_lgpl21 = _safe_destination(app, WEBCORE_LGPL21_DESTINATION, create_parent=True)
    packaged_angle_licenses = [
        _safe_destination(app, destination, create_parent=True)
        for _source, _name, _expected_hash, destination in angle_notice_sources
    ]
    packaged_webrtc_manifest = _safe_destination(
        app, WEBRTC_NOTICE_ROOT / "MANIFEST.json", create_parent=True)
    packaged_webrtc_notices = [
        _safe_destination(app, WEBRTC_NOTICE_ROOT / output_relative, create_parent=True)
        for _source_relative, output_relative, _digest, _size in webrtc_notices
    ]
    packaged_sandbox_manifest = _safe_destination(
        app, SANDBOX_NOTICE_ROOT / "MANIFEST.json", create_parent=True)
    packaged_sandbox_sources = [
        _safe_destination(app, SANDBOX_NOTICE_ROOT / name, create_parent=True)
        for name, _source_path, _runtime_path, _size in sandbox_rows
    ]
    packaged_source_candidate_manifest = _safe_destination(
        app, SOURCE_CANDIDATE_NOTICE_ROOT / "MANIFEST.json", create_parent=True)
    packaged_source_candidate_files = [
        _safe_destination(app, SOURCE_CANDIDATE_NOTICE_ROOT / row["outputPath"],
                          create_parent=True)
        for row in source_candidate_manifest["entries"]
    ]
    original_markdown = markdown.read_text(encoding="utf-8")
    original_html_bytes = html_notice.read_bytes()
    compliance_manifest = _compliance_manifest(app, original_html_bytes)
    original_html = original_html_bytes.decode("utf-8")
    markdown_text = _remove_owned_markdown_sections(original_markdown)
    html_text = _remove_owned_html_sections(original_html)
    section = render_markdown(library_hash)
    html_section = render_html(library_hash)
    lgpl2_markdown = render_lgpl2_markdown()
    lgpl2_html = render_lgpl2_html()
    lgpl21_markdown = render_lgpl21_markdown()
    lgpl21_html = render_lgpl21_html()
    angle_markdown = render_angle_markdown(angle_hash)
    angle_html = render_angle_html(angle_hash)
    webrtc_markdown = render_webrtc_markdown(webrtc_hash, webrtc_manifest, webrtc_notices)
    webrtc_html = render_webrtc_html(webrtc_hash, webrtc_manifest, webrtc_notices)
    webinspector_markdown = render_webinspector_markdown()
    webinspector_html = render_webinspector_html()
    sandbox_markdown = render_sandbox_markdown(sandbox_rows)
    sandbox_html = render_sandbox_html(sandbox_rows)
    source_candidate_markdown = render_source_candidate_markdown(source_candidate_manifest)
    source_candidate_html = render_source_candidate_html(source_candidate_manifest)
    lowered_html = html_text.lower()
    closing_body = lowered_html.rfind("</body>")
    if closing_body >= 0:
        insertion_point = closing_body
    else:
        # Chromium's generated THIRD-PARTY-NOTICES.html is an HTML fragment:
        # it opens <body> and intentionally omits closing body/html tags.
        # Place the notice before </html> when present, or at EOF for that
        # fragment form. Refuse a document with no body at all.
        if re.search(r"<body(?:\s[^>]*)?>", lowered_html) is None:
            raise NoticeError("generated third-party HTML notice has no body element")
        closing_html = lowered_html.rfind("</html>")
        insertion_point = closing_html if closing_html >= 0 else len(html_text)
    new_html = (
        html_text[:insertion_point] + html_section + "\n" + lgpl2_html + "\n"
        + lgpl21_html + "\n"
        + angle_html + "\n"
        + webrtc_html + "\n"
        + webinspector_html + "\n"
        + sandbox_html + "\n"
        + source_candidate_html + "\n"
        + html_text[insertion_point:]
    )
    # Validate every input and destination before the first write.
    if (sha256_file(source_license) != LICENSE_SHA256
            or sha256_file(source_lgpl2) != WEBCORE_LGPL2_SHA256
            or sha256_file(source_lgpl21) != WEBCORE_LGPL21_SHA256
            or sha256_file(angle_library) != angle_hash
            or sha256_file(webrtc_library) != webrtc_hash
            or hashlib.sha256((project_root / WEBRTC_MANIFEST_SOURCE).read_bytes()).hexdigest()
            != WEBRTC_MANIFEST_SHA256):
        raise NoticeError("a pinned runtime license text changed during packaging")
    for relative, _name, expected_hash, _destination in angle_notice_sources:
        source = project_root / relative
        if sha256_file(source) != expected_hash:
            raise NoticeError(f"pinned WebKit license text changed during packaging: {relative}")
    for source_relative, output_relative, digest, size in webrtc_notices:
        source = _physical_path_beneath(
            project_root / WEBRTC_CANDIDATE_ROOT, output_relative,
            label=f"pinned WebRTC notice {source_relative}")
        if source.stat().st_size != size or sha256_file(source) != digest:
            raise NoticeError(f"pinned WebRTC notice changed during packaging: {source_relative}")
    _webinspector_notice_sources(project_root, runtime_frameworks)
    _sandbox_notice_sources(project_root)
    _atomic_write(packaged_license, source_license.read_bytes(), mode=0o644)
    _atomic_write(packaged_lgpl2, source_lgpl2.read_bytes(), mode=0o644)
    _atomic_write(packaged_lgpl21, source_lgpl21.read_bytes(), mode=0o644)
    for (relative, _name, _expected_hash, _destination), packaged in zip(
            angle_notice_sources, packaged_angle_licenses):
        _atomic_write(packaged, (project_root / relative).read_bytes(), mode=0o644)
    _atomic_write(packaged_webrtc_manifest, (project_root / WEBRTC_MANIFEST_SOURCE).read_bytes(), mode=0o644)
    for (_source_relative, output_relative, _digest, _size), packaged in zip(
            webrtc_notices, packaged_webrtc_notices):
        source = project_root / WEBRTC_CANDIDATE_ROOT / output_relative
        _atomic_write(packaged, source.read_bytes(), mode=0o644)
    _atomic_write(packaged_sandbox_manifest,
                  (project_root / SANDBOX_SOURCE_ROOT / "MANIFEST.json").read_bytes(), mode=0o644)
    for (name, _source_path, _runtime_path, _size), packaged in zip(
            sandbox_rows, packaged_sandbox_sources):
        _atomic_write(packaged, (project_root / SANDBOX_SOURCE_ROOT / name).read_bytes(), mode=0o644)
    _atomic_write(packaged_source_candidate_manifest, source_candidate_manifest_bytes, mode=0o644)
    for (_source_path, source, expected_hash, expected_size), packaged in zip(
            source_candidate_sources, packaged_source_candidate_files):
        data = source.read_bytes()
        if len(data) != expected_size or hashlib.sha256(data).hexdigest() != expected_hash:
            raise NoticeError("WebKit source license candidate changed during packaging")
        _atomic_write(packaged, data, mode=0o644)
    new_markdown = (markdown_text.rstrip() + "\n\n" + section + "\n"
                    + lgpl2_markdown + "\n" + lgpl21_markdown + "\n"
                    + angle_markdown + "\n" + webrtc_markdown + "\n"
                    + webinspector_markdown + "\n" + sandbox_markdown + "\n"
                    + source_candidate_markdown)
    _atomic_write(markdown, new_markdown.encode("utf-8"))
    new_html_bytes = new_html.encode("utf-8")
    _atomic_write(html_notice, new_html_bytes)
    _refresh_compliance_notice_hash(compliance_manifest, new_html_bytes)
    verify_owned_webkit_notices(app, runtime_frameworks, project_root=project_root)
    return {
        "runtimeLibrarySHA256": library_hash,
        "licenseSHA256": LICENSE_SHA256,
        "webcoreLGPL2SHA256": WEBCORE_LGPL2_SHA256,
        "webcoreLGPL21SHA256": WEBCORE_LGPL21_SHA256,
        "angleRuntimeSHA256": angle_hash,
        "angleLicenseSHA256": ANGLE_LICENSE_SHA256,
        "xxhashLicenseSHA256": XXHASH_LICENSE_SHA256,
        "chromiumAngleLicenseSHA256": CHROMIUM_ANGLE_LICENSE_SHA256,
        "webrtcRuntimeSHA256": webrtc_hash,
        "webrtcManifestSHA256": WEBRTC_MANIFEST_SHA256,
        "webrtcNoticeCount": str(len(webrtc_notices)),
        "webInspectorExternalLicenseCount": str(len(WEBINSPECTOR_LICENSES)),
        "webKitSandboxSourceNoticeCount": str(len(sandbox_rows)),
        "webKitSourceCandidateNoticeCount": str(len(source_candidate_sources)),
        "webKitSourceCandidateManifestSHA256": hashlib.sha256(source_candidate_manifest_bytes).hexdigest(),
    }


def verify_owned_webkit_notices(
    app: Path, runtime_frameworks: Path | None = None, *, project_root: Path = PROJECT_ROOT,
) -> dict[str, str]:
    """Fail closed unless app notices and the packaged license match the runtime."""
    source_license = _license(project_root)
    source_lgpl2 = _webcore_lgpl2_license(project_root)
    source_lgpl21 = _webcore_lgpl21_license(project_root)
    angle_notice_sources = _angle_notice_sources(project_root)
    webrtc_manifest, webrtc_notices = _webrtc_notice_sources(project_root)
    _webinspector_notice_sources(project_root, runtime_frameworks)
    sandbox_rows = _sandbox_notice_sources(project_root)
    source_candidate_manifest, source_candidate_manifest_bytes, source_candidate_sources = (
        _source_candidate_notice_sources(project_root))
    markdown = _safe_destination(app, NOTICE_DESTINATION, create_parent=False)
    html_notice = _safe_destination(app, HTML_DESTINATION, create_parent=False)
    packaged_license = _safe_destination(app, LICENSE_DESTINATION, create_parent=False)
    packaged_lgpl2 = _safe_destination(app, WEBCORE_LGPL2_DESTINATION, create_parent=False)
    packaged_lgpl21 = _safe_destination(app, WEBCORE_LGPL21_DESTINATION, create_parent=False)
    packaged_angle_licenses = [
        _safe_destination(app, destination, create_parent=False)
        for _source, _name, _expected_hash, destination in angle_notice_sources
    ]
    packaged_webrtc_manifest = _safe_destination(
        app, WEBRTC_NOTICE_ROOT / "MANIFEST.json", create_parent=False)
    packaged_webrtc_notices = [
        _safe_destination(app, WEBRTC_NOTICE_ROOT / output_relative, create_parent=False)
        for _source_relative, output_relative, _digest, _size in webrtc_notices
    ]
    packaged_sandbox_manifest = _safe_destination(
        app, SANDBOX_NOTICE_ROOT / "MANIFEST.json", create_parent=False)
    packaged_sandbox_sources = [
        _safe_destination(app, SANDBOX_NOTICE_ROOT / name, create_parent=False)
        for name, _source_path, _runtime_path, _size in sandbox_rows
    ]
    packaged_source_candidate_manifest = _safe_destination(
        app, SOURCE_CANDIDATE_NOTICE_ROOT / "MANIFEST.json", create_parent=False)
    packaged_source_candidate_files = [
        _safe_destination(app, SOURCE_CANDIDATE_NOTICE_ROOT / row["outputPath"],
                          create_parent=False)
        for row in source_candidate_manifest["entries"]
    ]
    if sha256_file(packaged_license) != LICENSE_SHA256:
        raise NoticeError("packaged Swift runtime license SHA-256 mismatch")
    if packaged_license.read_bytes() != source_license.read_bytes():
        raise NoticeError("packaged Swift runtime license differs from canonical license")
    if sha256_file(packaged_lgpl2) != WEBCORE_LGPL2_SHA256:
        raise NoticeError("packaged WebCore LGPL-2 license SHA-256 mismatch")
    if packaged_lgpl2.read_bytes() != source_lgpl2.read_bytes():
        raise NoticeError("packaged WebCore LGPL-2 license differs from pinned source text")
    if sha256_file(packaged_lgpl21) != WEBCORE_LGPL21_SHA256:
        raise NoticeError("packaged WebCore LGPL-2.1 license SHA-256 mismatch")
    if packaged_lgpl21.read_bytes() != source_lgpl21.read_bytes():
        raise NoticeError("packaged WebCore LGPL-2.1 license differs from pinned source text")
    for (source_relative, name, expected_hash, _destination), packaged in zip(
            angle_notice_sources, packaged_angle_licenses):
        source = project_root / source_relative
        if sha256_file(packaged) != expected_hash:
            raise NoticeError(f"packaged WebKit license SHA-256 mismatch: {name}")
        if packaged.read_bytes() != source.read_bytes():
            raise NoticeError(f"packaged WebKit license differs from pinned source: {name}")
    if (sha256_file(packaged_webrtc_manifest) != WEBRTC_MANIFEST_SHA256
            or packaged_webrtc_manifest.read_bytes()
            != (project_root / WEBRTC_MANIFEST_SOURCE).read_bytes()):
        raise NoticeError("packaged WebRTC candidate manifest differs from pinned manifest")
    for (_source_relative, output_relative, digest, size), packaged in zip(
            webrtc_notices, packaged_webrtc_notices):
        if packaged.stat().st_size != size or sha256_file(packaged) != digest:
            raise NoticeError(f"packaged WebRTC notice hash/size mismatch: {output_relative}")
    canonical_sandbox_manifest = project_root / SANDBOX_SOURCE_ROOT / "MANIFEST.json"
    if (sha256_file(packaged_sandbox_manifest) != SANDBOX_MANIFEST_SHA256
            or packaged_sandbox_manifest.read_bytes() != canonical_sandbox_manifest.read_bytes()):
        raise NoticeError("packaged WebKit sandbox manifest differs from pinned source")
    for (name, _source_path, _runtime_path, size), packaged in zip(
            sandbox_rows, packaged_sandbox_sources):
        source = project_root / SANDBOX_SOURCE_ROOT / name
        if packaged.stat().st_size != size or packaged.read_bytes() != source.read_bytes():
            raise NoticeError(f"packaged WebKit sandbox source differs from pinned source: {name}")
    if (sha256_file(packaged_source_candidate_manifest) != hashlib.sha256(source_candidate_manifest_bytes).hexdigest()
            or packaged_source_candidate_manifest.read_bytes() != source_candidate_manifest_bytes):
        raise NoticeError("packaged WebKit source-candidate manifest differs from pinned evidence")
    for (source_path, source, expected_hash, expected_size), packaged in zip(
            source_candidate_sources, packaged_source_candidate_files):
        if (packaged.stat().st_size != expected_size or sha256_file(packaged) != expected_hash
                or packaged.read_bytes() != source.read_bytes()):
            raise NoticeError(f"packaged WebKit source license candidate differs: {source_path}")
    source_candidate_root = app / SOURCE_CANDIDATE_NOTICE_ROOT
    expected_source_candidate_paths = {
        "MANIFEST.json", *("files/" + row["sourcePath"] for row in source_candidate_manifest["entries"])
    }
    actual_source_candidate_paths = {
        path.relative_to(source_candidate_root).as_posix()
        for path in source_candidate_root.rglob("*")
        if path.is_file() or path.is_symlink()
    }
    if actual_source_candidate_paths != expected_source_candidate_paths:
        raise NoticeError("packaged WebKit source-candidate directory has unexpected files")
    markdown_text = markdown.read_text(encoding="utf-8")
    html_text = html_notice.read_text(encoding="utf-8")
    if (markdown_text.count(SECTION_MARKER) != 1 or html_text.count(HTML_MARKER) != 1
            or markdown_text.splitlines().count(LGPL2_SECTION_MARKER) != 1
            or html_text.count(LGPL2_HTML_MARKER) != 1
            or markdown_text.splitlines().count(LGPL21_SECTION_MARKER) != 1
            or html_text.count(LGPL21_HTML_MARKER) != 1
            or markdown_text.count(ANGLE_SECTION_MARKER) != 1
            or html_text.count(ANGLE_HTML_MARKER) != 1
            or markdown_text.count(WEBRTC_SECTION_MARKER) != 1
            or html_text.count(WEBRTC_HTML_MARKER) != 1
            or markdown_text.splitlines().count(WEBINSPECTOR_SECTION_MARKER) != 1
            or html_text.count(WEBINSPECTOR_HTML_MARKER) != 1
            or markdown_text.splitlines().count(SANDBOX_SECTION_MARKER) != 1
            or html_text.count(SANDBOX_HTML_MARKER) != 1
            or markdown_text.splitlines().count(SOURCE_CANDIDATE_SECTION_MARKER) != 1
            or html_text.count(SOURCE_CANDIDATE_HTML_MARKER) != 1):
        raise NoticeError("owned-WebKit runtime notice is missing or duplicated")
    if (render_lgpl2_markdown().rstrip() not in markdown_text
            or render_lgpl2_html() not in html_text
            or render_lgpl21_markdown().rstrip() not in markdown_text
            or render_lgpl21_html() not in html_text):
        raise NoticeError("WebKit LGPL notice does not match pinned license text")
    if (render_webinspector_markdown().rstrip() not in markdown_text
            or render_webinspector_html() not in html_text):
        raise NoticeError("WebInspectorUI resource index differs from pinned license texts")
    if (render_sandbox_markdown(sandbox_rows).rstrip() not in markdown_text
            or render_sandbox_html(sandbox_rows) not in html_text):
        raise NoticeError("WebKit sandbox notice index differs from pinned source")
    if (render_source_candidate_markdown(source_candidate_manifest).rstrip() not in markdown_text
            or render_source_candidate_html(source_candidate_manifest) not in html_text):
        raise NoticeError("WebKit source-candidate notice differs from pinned crosswalk")
    if runtime_frameworks is not None:
        webrtc_hash = sha256_file(_webrtc_library(runtime_frameworks))
        if render_webrtc_markdown(webrtc_hash, webrtc_manifest, webrtc_notices).rstrip() not in markdown_text:
            raise NoticeError("WebKit Markdown notice does not match WebRTC image or manifest")
        if render_webrtc_html(webrtc_hash, webrtc_manifest, webrtc_notices) not in html_text:
            raise NoticeError("WebKit HTML notice does not match WebRTC image or manifest")
    elif (WEBRTC_MANIFEST_SHA256 not in markdown_text
          or str(len(webrtc_notices)) not in markdown_text
          or any(digest not in markdown_text for _source, _output, digest, _size in webrtc_notices)):
        raise NoticeError("WebKit Markdown notice does not identify the pinned WebRTC candidate")
    if runtime_frameworks is not None:
        angle_hash = sha256_file(_angle_library(runtime_frameworks))
        if render_angle_markdown(angle_hash).rstrip() not in markdown_text:
            raise NoticeError("WebKit Markdown notice does not match ANGLE bytes")
        if render_angle_html(angle_hash) not in html_text:
            raise NoticeError("WebKit HTML notice does not match ANGLE bytes")
    if runtime_frameworks is not None:
        library_hash = sha256_file(_compatibility_span(runtime_frameworks))
        if render_markdown(library_hash).rstrip() not in markdown_text:
            raise NoticeError("WebKit Markdown notice does not match CompatibilitySpan bytes")
        if render_html(library_hash) not in html_text:
            raise NoticeError("WebKit HTML notice does not match CompatibilitySpan bytes")
    elif (LICENSE_NAME not in markdown_text or LICENSE_SHA256 not in markdown_text
          or WEBCORE_LGPL2_NAME not in markdown_text
          or WEBCORE_LGPL2_SHA256 not in markdown_text
          or WEBCORE_LGPL21_NAME not in markdown_text
          or WEBCORE_LGPL21_SHA256 not in markdown_text
          or ANGLE_LICENSE_NAME not in markdown_text
          or ANGLE_LICENSE_SHA256 not in markdown_text
          or XXHASH_LICENSE_NAME not in markdown_text
          or XXHASH_LICENSE_SHA256 not in markdown_text
          or CHROMIUM_ANGLE_LICENSE_NAME not in markdown_text
          or CHROMIUM_ANGLE_LICENSE_SHA256 not in markdown_text):
        raise NoticeError("WebKit Markdown notice does not identify the applicable license")
    return {"licenseSHA256": LICENSE_SHA256, "webcoreLGPL2SHA256": WEBCORE_LGPL2_SHA256,
            "webcoreLGPL21SHA256": WEBCORE_LGPL21_SHA256,
            "webKitSourceCandidateNoticeCount": str(len(source_candidate_sources)),
            "webKitSourceCandidateManifestSHA256": hashlib.sha256(source_candidate_manifest_bytes).hexdigest()}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--install", action="store_true")
    mode.add_argument("--verify", action="store_true")
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--runtime-frameworks", type=Path)
    parser.add_argument("--project-root", type=Path, default=PROJECT_ROOT)
    args = parser.parse_args()
    try:
        if args.install:
            if args.runtime_frameworks is None:
                raise NoticeError("--runtime-frameworks is required for installation")
            result = install_owned_webkit_notices(
                args.app, args.runtime_frameworks, project_root=args.project_root)
        else:
            result = verify_owned_webkit_notices(
                args.app, args.runtime_frameworks, project_root=args.project_root)
    except (OSError, NoticeError) as error:
        print(f"WebKit runtime notice check failed: {error}", file=sys.stderr)
        return 1
    print("PASS: owned-WebKit runtime notices verified")
    print(f"License SHA-256: {result['licenseSHA256']}")
    print(f"WebCore LGPL-2 text SHA-256: {result['webcoreLGPL2SHA256']}")
    print(f"WebCore LGPL-2.1 text SHA-256: {result['webcoreLGPL21SHA256']}")
    if "angleRuntimeSHA256" in result:
        print(f"ANGLE image SHA-256: {result['angleRuntimeSHA256']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
