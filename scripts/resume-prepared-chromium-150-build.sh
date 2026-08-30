#!/bin/bash

set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: scripts/resume-prepared-chromium-150-build.sh [build-root]

Resume an already prepared NeAntik Chromium 150 source tree without re-running
source retrieval, pruning, patch application, or domain substitution.

Default build root:
  /private/tmp/nevision-chromium-150

Optional environment:
  NEANTIK_NINJA_JOBS=4
EOF
}

if [[ $# -gt 1 ]]; then
  usage
  exit 64
fi

BUILD_ROOT="${1:-/private/tmp/nevision-chromium-150}"
SOURCE_DIR="$BUILD_ROOT/build/src"
PYTHON_DEPS="${NEANTIK_PYTHON_DEPS:-/private/tmp/nevision-python-deps}"
JOBS="${NEANTIK_NINJA_JOBS:-4}"

if [[ "$BUILD_ROOT" != /* ]]; then
  echo "Build root must be absolute: $BUILD_ROOT" >&2
  exit 64
fi

if [[ ! "$JOBS" =~ ^[1-9][0-9]*$ ]] || (( JOBS > 12 )); then
  echo "NEANTIK_NINJA_JOBS must be an integer from 1 through 12." >&2
  exit 64
fi

if [[ ! -d "$SOURCE_DIR" ]]; then
  echo "Prepared Chromium source root is missing: $SOURCE_DIR" >&2
  exit 66
fi

if [[ ! -x "$SOURCE_DIR/out/Default/gn" ]]; then
  echo "Prepared GN binary is missing: $SOURCE_DIR/out/Default/gn" >&2
  exit 66
fi

if [[ ! -f "$SOURCE_DIR/out/Default/args.gn" ]]; then
  echo "Prepared args.gn is missing: $SOURCE_DIR/out/Default/args.gn" >&2
  exit 66
fi

if ! grep -Eq '^[[:space:]]*target_cpu[[:space:]]*=[[:space:]]*"arm64"[[:space:]]*$' \
  "$SOURCE_DIR/out/Default/args.gn"
then
  echo "args.gn must target arm64." >&2
  exit 65
fi

if ! grep -Eq '^[[:space:]]*chrome_pgo_phase[[:space:]]*=[[:space:]]*0[[:space:]]*$' \
  "$SOURCE_DIR/out/Default/args.gn"
then
  echo "args.gn must disable PGO downloads with chrome_pgo_phase = 0." >&2
  exit 65
fi

METAL_TRUE_COUNT="$(
  grep -Ec '^[[:space:]]*angle_enable_metal[[:space:]]*=[[:space:]]*true[[:space:]]*$' \
    "$SOURCE_DIR/out/Default/args.gn" || true
)"
METAL_FALSE_COUNT="$(
  grep -Ec '^[[:space:]]*angle_enable_metal[[:space:]]*=[[:space:]]*false[[:space:]]*$' \
    "$SOURCE_DIR/out/Default/args.gn" || true
)"
if (( METAL_TRUE_COUNT == 0 && METAL_FALSE_COUNT == 0 )); then
  printf '\n%s\n' 'angle_enable_metal = true' >> "$SOURCE_DIR/out/Default/args.gn"
elif (( METAL_TRUE_COUNT != 1 || METAL_FALSE_COUNT != 0 )); then
  echo "args.gn must declare exactly one angle_enable_metal = true and no false declaration." >&2
  exit 65
fi

if ! xcrun metal -v >/dev/null 2>&1 || ! xcrun --find metallib >/dev/null 2>&1; then
  cat >&2 <<'EOF'
Apple Metal Toolchain is not active.

Run this in a normal Terminal first:

  xcodebuild -downloadComponent MetalToolchain
  xcrun metal -v
  xcrun --find metallib

Then rerun this script.
EOF
  exit 69
fi

METAL_BIN="$(dirname "$(xcrun --find metal)")"
export PATH="$PYTHON_DEPS/bin:$SOURCE_DIR/third_party/llvm-build/Release+Asserts/bin:$SOURCE_DIR/third_party/rust-toolchain/bin:$SOURCE_DIR/uc_staging/depot_tools:$METAL_BIN:$PATH"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/nevision-clang-module-cache}"
export MODULE_CACHE_DIR="${MODULE_CACHE_DIR:-/private/tmp/nevision-clang-module-cache}"
export NEANTIK_METAL_MODULE_CACHE="${NEANTIK_METAL_MODULE_CACHE:-/private/tmp/nevision-metal-module-cache}"
export NEANTIK_METAL_BIN_DIR="$METAL_BIN"

mkdir -p "$CLANG_MODULE_CACHE_PATH" "$NEANTIK_METAL_MODULE_CACHE"

ANGLE_METAL_BUILD_GN="$SOURCE_DIR/third_party/angle/src/libANGLE/renderer/metal/BUILD.gn"
python3 - "$ANGLE_METAL_BUILD_GN" "$NEANTIK_METAL_MODULE_CACHE" <<'PY'
from pathlib import Path
import sys

build_gn = Path(sys.argv[1])
module_cache = sys.argv[2]
marker = f'-fmodules-cache-path={module_cache}'
text = build_gn.read_text(encoding="utf-8")
if marker not in text:
    needle = '''      }

      args += invoker.args
'''
    replacement = f'''      }}

      if (metal_tool == "metal") {{
        args += [ "{marker}" ]
      }}

      args += invoker.args
'''
    if needle not in text:
        raise SystemExit(f"Could not patch ANGLE Metal module cache path in {build_gn}")
    build_gn.write_text(text.replace(needle, replacement, 1), encoding="utf-8")
PY

cd "$SOURCE_DIR"
"$SOURCE_DIR/out/Default/gn" gen out/Default --fail-on-unused-args

NINJA_STATUS='[%f/%t %es %r jobs] ' \
  ninja -C out/Default -j"$JOBS" chrome

echo
echo "Chromium 150 build finished:"
APP_BUNDLE="$SOURCE_DIR/out/Default/NeAntik Browser.app"
if [[ ! -x "$APP_BUNDLE/Contents/MacOS/NeAntik Browser" ]]; then
  echo "Expected NeAntik Browser.app was not produced: $APP_BUNDLE" >&2
  exit 70
fi
echo "$APP_BUNDLE"
