#!/usr/bin/env python3
"""Apply the locked canonical Apple tuple overlay to Chromium 154.0.8037.93.

This wrapper reuses the reviewed tuple renderer but has an M154-specific
source identity and exact pre/postimage lock. It must run after the owned
runtime patches and macOS packaging layer, before GN generation/build.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import subprocess
import sys
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
GENERATOR_PATH = PROJECT_ROOT / "scripts" / "apply-owned-runtime-device-tuples.py"
CATALOG_PATH = PROJECT_ROOT / "runtime" / "apple-device-tuples.json"
EXPECTED_CATALOG_SHA256 = (
    "3c355a6a6708386c410c98cb9310a6f6e62ea5da065eb0faf0290b2a4a4ff6f2"
)
EXPECTED_SOURCE_COMMIT = "f89f3a4363808e117c592adedcf9947882ac3b79"
EXPECTED_SOURCE_TREE = "658e81c77627fcf91e6784bd353e0d31a4ca70b5"
EXPECTED_CHROMIUM_VERSION = "154.0.8037.93"

PREIMAGE_SHA256 = {
    "third_party/blink/renderer/core/frame/navigator_concurrent_hardware.cc":
        "0c71caabd085e8ec7d976790284a4b8f144ea8fce6fb17996018a1490264468a",
    "third_party/blink/renderer/core/frame/navigator_device_memory.cc":
        "53a00115a73944d7dec9d4ef9c52ad422c508843e43fa5fbcf2db037bb10d63f",
    "third_party/blink/renderer/core/frame/screen.cc":
        "98b03954aeecf4373e0920999651e85c763a6b160d3eaf43b3cb1a1e08bad921",
    "third_party/blink/renderer/core/frame/local_dom_window.cc":
        "4124fe489ccc442d6bdba4cf0fa1469549667170bf24812499911c2d114e6cab",
    "third_party/blink/renderer/modules/webgl/webgl_rendering_context_base.cc":
        "c4169564562f22fe036e1b0658f1d32ee8102e958bf7c1570235a53c2af8d28d",
    "components/embedder_support/user_agent_utils.cc":
        "167e2d4232ee20102c3cd2141563e1a9df3cb04963bacea96d81305e72e3f703",
    "components/embedder_support/BUILD.gn":
        "355120ca227322e7c2c4a2691c8573c2e7b56a0d4c8f8c34b93286a373e4ee38",
}

POSTIMAGE_SHA256 = {
    "components/ungoogled/neantik_apple_device_tuples.h":
        "3ef1b5bf96166edcde85177ba4ba14fac9aabf724cb8cb0e14c1076b0648214b",
    "third_party/blink/renderer/core/frame/navigator_concurrent_hardware.cc":
        "ebc2b259e2fc467733904e2eac27621a2e2cd0a415934f94ab1739ee27f0d5aa",
    "third_party/blink/renderer/core/frame/navigator_device_memory.cc":
        "c627f44995fb92e3db4ba43eb75bd91fd53defa8f59f8a18a0b9ce8153d38a8a",
    "third_party/blink/renderer/core/frame/screen.cc":
        "82efdc31e4bae7a895e53bc54f33dc1797fdd05361136430e0655c06fc7f8d48",
    "third_party/blink/renderer/core/frame/local_dom_window.cc":
        "9a6916b77dd58f5860a7b7b2fc2124615b0a5db0c2a73e56134380f59212a087",
    "third_party/blink/renderer/modules/webgl/webgl_rendering_context_base.cc":
        "ff4756e11005c719c4cfeaee06ad783a073d8b5a02b9290aba59879d184a26b7",
    "components/embedder_support/user_agent_utils.cc":
        "6849c382d3bf1ca5d8fa2320d945547d429c45a5c7e8638428cd2e9856e3a996",
    "components/embedder_support/BUILD.gn":
        "1c37df24e83fae9ae7a04c6e12ce830d54d01f5a2cdc045a960aaf3f7418ddac",
}


class TupleOverlay154Error(ValueError):
    pass


def transform_webgl_154(renderer, text: str) -> str:
    """Render tuple identity and the M154-safe pixel-span changes together.

    The WebGL renderer and bounds-safe readback changes were historically
    bundled into owned patch group 23. Keeping their complete postimage in the
    final tuple overlay makes the replay order deterministic: all owned source
    patches apply first, then this locked transform runs once.
    """
    text = renderer.transform_webgl(text)
    text = renderer.replace_once(
        text,
        "              String::Format(\n"
        "                  \"ANGLE (Apple, ANGLE Metal Renderer: Apple %s, \"\n"
        "                  \"Unspecified Version)\",\n"
        "                  tuple.gpu_model));",
        "              StrCat({\"ANGLE (Apple, ANGLE Metal Renderer: Apple \",\n"
        '                      String(tuple.gpu_model), ", Unspecified Version)"}));',
        label="M154 bounded WebGL renderer formatting",
    )
    text = renderer.replace_once(
        text,
        '#include "base/compiler_specific.h"\n',
        '#include "base/compiler_specific.h"\n'
        '#include "base/containers/span.h"\n',
        label="M154 bounded WebGL span include",
    )
    text = renderer.replace_once(
        text,
        "    const size_t sample_count = std::min<size_t>(pixel_count, 16);\n",
        "    base::span<uint8_t> output =\n"
        "        pixels->ByteSpanMaybeShared().subspan(offset_in_bytes.ValueOrDie());\n"
        "    const size_t sample_count = std::min<size_t>(pixel_count, 16);\n",
        label="M154 bounds-checked WebGL output span",
    )
    return renderer.replace_once(
        text,
        "      data[byte_index] = static_cast<uint8_t>(\n"
        "          data[byte_index] >= 255 - delta ? data[byte_index] - delta\n"
        "                                          : data[byte_index] + delta);",
        "      output[byte_index] = static_cast<uint8_t>(\n"
        "          output[byte_index] >= 255 - delta ? output[byte_index] - delta\n"
        "                                            : output[byte_index] + delta);",
        label="M154 bounds-checked WebGL output access",
    )


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def load_renderer():
    spec = importlib.util.spec_from_file_location(
        "neantik_owned_tuple_renderer_154", GENERATOR_PATH
    )
    if spec is None or spec.loader is None:
        raise TupleOverlay154Error("cannot load the reviewed tuple renderer")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    module.PREIMAGE_SHA256 = PREIMAGE_SHA256
    module.POSTIMAGE_SHA256 = POSTIMAGE_SHA256
    webgl_path = "third_party/blink/renderer/modules/webgl/webgl_rendering_context_base.cc"
    module.TRANSFORMS[webgl_path] = (
        lambda text: transform_webgl_154(module, text)
    )
    return module


def verify_source_identity(source_root: Path, renderer) -> None:
    if not source_root.is_absolute() or source_root.is_symlink():
        raise TupleOverlay154Error(
            "source root must be an absolute non-symlink directory"
        )
    if not source_root.is_dir():
        raise TupleOverlay154Error("source root is not a directory")
    result = subprocess.run(
        ["git", "-C", str(source_root), "rev-parse", "HEAD"],
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode or result.stdout.strip() != EXPECTED_SOURCE_COMMIT:
        raise TupleOverlay154Error("source HEAD does not match the M154 lock")
    result = subprocess.run(
        ["git", "-C", str(source_root), "rev-parse", "HEAD^{tree}"],
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode or result.stdout.strip() != EXPECTED_SOURCE_TREE:
        raise TupleOverlay154Error("source tree does not match the M154 lock")
    version_file = source_root / "chrome" / "VERSION"
    if not version_file.is_file() or version_file.is_symlink():
        raise TupleOverlay154Error("Chromium VERSION file is missing or unsafe")
    fields = dict(
        line.split("=", 1)
        for line in version_file.read_text(encoding="utf-8").splitlines()
        if "=" in line
    )
    actual_version = ".".join(
        fields.get(key, "") for key in ("MAJOR", "MINOR", "BUILD", "PATCH")
    )
    if actual_version != EXPECTED_CHROMIUM_VERSION:
        raise TupleOverlay154Error(
            f"source VERSION mismatch: {actual_version}"
        )
    if not CATALOG_PATH.is_file() or CATALOG_PATH.is_symlink():
        raise TupleOverlay154Error("canonical Apple tuple catalog is missing")
    if sha256_bytes(CATALOG_PATH.read_bytes()) != EXPECTED_CATALOG_SHA256:
        raise TupleOverlay154Error("canonical Apple tuple catalog hash mismatch")


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Generate/apply or verify NeAntik's canonical Apple tuples on "
            "the locked Chromium 154.0.8037.93 source."
        )
    )
    parser.add_argument("source_root", type=Path)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--show-postimages", action="store_true")
    args = parser.parse_args()
    if args.source_root.is_symlink():
        print("Tuple overlay failed: source root must not be a symlink", file=sys.stderr)
        return 65
    source_root = args.source_root.resolve()
    try:
        renderer = load_renderer()
        verify_source_identity(source_root, renderer)
        rendered = renderer.rendered_postimages(source_root)
    except Exception as error:
        print(f"M154 tuple overlay failed: {error}", file=sys.stderr)
        return 65

    actual = {relative: sha256_bytes(data) for relative, data in rendered.items()}
    if args.show_postimages:
        for relative in sorted(actual):
            print(f"{relative} {actual[relative]}")
        return 0
    mismatches = [
        f"{relative}: expected {POSTIMAGE_SHA256[relative]}, rendered {actual[relative]}"
        for relative in sorted(actual)
        if actual[relative] != POSTIMAGE_SHA256[relative]
    ]
    if mismatches:
        print("M154 tuple postimage lock mismatch:\n" + "\n".join(mismatches), file=sys.stderr)
        return 65
    if args.check:
        for relative, data in rendered.items():
            path = source_root / relative
            if not path.is_file() or path.is_symlink() or path.read_bytes() != data:
                print(f"M154 tuple overlay is not applied: {relative}", file=sys.stderr)
                return 65
        print(f"M154 canonical Apple tuple overlay verified: {len(rendered)} postimages.")
        return 0
    for relative, data in rendered.items():
        path = source_root / relative
        if path.is_file() and not path.is_symlink() and path.read_bytes() == data:
            continue
        path.parent.mkdir(parents=True, exist_ok=True)
        mode = path.stat().st_mode if path.exists() else 0o644
        renderer.atomic_write(path, data, mode=mode)
        print(f"APPLY {relative}")
    print(f"M154 canonical Apple tuple overlay applied: {len(rendered)} postimages.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
