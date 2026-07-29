#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TOOLS_PATH="$SCRIPT_DIR/runtime-tools"

usage() {
  echo "Usage: $0 /absolute/path/to/nevision-chromium-build [prepare|configure|build|all]" >&2
}

if [[ $# -lt 1 || $# -gt 2 || -z "${1:-}" ]]; then
  usage
  exit 64
fi

BUILD_ROOT="$1"
PHASE="${2:-all}"

if [[ "$BUILD_ROOT" != /* ]]; then
  echo "Build root must be an absolute path." >&2
  exit 64
fi

case "$PHASE" in
  prepare|configure|build|all) ;;
  *)
    usage
    exit 64
    ;;
esac

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "NeAntik runtime builds are supported only on Apple Silicon." >&2
  exit 65
fi

if [[ ! -d "$BUILD_ROOT/.git" ||
      ! -d "$BUILD_ROOT/ungoogled-chromium/.git" ]]; then
  echo "Prepare the pinned source pair first:" >&2
  echo "  $SCRIPT_DIR/prepare-runtime-source.sh $BUILD_ROOT" >&2
  exit 66
fi

"$SCRIPT_DIR/verify-runtime-source.sh" "$BUILD_ROOT"

BUILD_DIR="$BUILD_ROOT/build"
SOURCE_DIR="$BUILD_DIR/src"
CACHE_DIR="$BUILD_DIR/download_cache"
TOOLS_DIR="$BUILD_DIR/nevision-tools"
PIP_CACHE_DIR="$BUILD_DIR/pip-cache"
PYTHON_CACHE_DIR="$BUILD_DIR/pycache"
SOURCE_STAMP="$BUILD_DIR/.nevision-source-ready-v1"
TOOLCHAIN_STAMP="$BUILD_DIR/.nevision-toolchain-ready-v1"
CONFIG_STAMP="$BUILD_DIR/.nevision-config-ready-v1"
BUILD_LOG="$BUILD_DIR/nevision-runtime-arm64.log"
EXPECTED_CHROMIUM_VERSION="$(
  plutil -extract fingerprintChromium.chromiumVersion raw -o - \
    "$PROJECT_ROOT/runtime/fingerprint-chromium.lock.json"
)"

mkdir -p "$BUILD_DIR" "$CACHE_DIR" "$PIP_CACHE_DIR" "$PYTHON_CACHE_DIR"

if [[ ! -x "$TOOLS_DIR/bin/python3" ]]; then
  python3 -m venv "$TOOLS_DIR"
fi

export PIP_CACHE_DIR
export PYTHONPYCACHEPREFIX="$PYTHON_CACHE_DIR"
if [[ ! -x "$TOOLS_DIR/bin/ninja" ]] ||
   ! "$TOOLS_DIR/bin/python3" -c \
     'import importlib.metadata as m; assert m.version("ninja") == "1.13.0"; assert m.version("PySocks") == "1.7.1"; assert m.version("httplib2") == "0.32.0"' \
     >/dev/null 2>&1
then
  "$TOOLS_DIR/bin/python3" -m pip install \
    --disable-pip-version-check \
    "ninja==1.13.0" \
    "PySocks==1.7.1" \
    "httplib2==0.32.0"
fi

export PATH="$TOOLS_PATH:$TOOLS_DIR/bin:$PATH"

available_kib() {
  df -Pk "$BUILD_ROOT" | awk 'NR == 2 { print $4 }'
}

require_free_space() {
  local minimum_gib="$1"
  local minimum_kib=$((minimum_gib * 1024 * 1024))
  local actual_kib
  actual_kib="$(available_kib)"
  if (( actual_kib < minimum_kib )); then
    echo "At least ${minimum_gib} GiB free is required for this phase." >&2
    echo "Available: $((actual_kib / 1024 / 1024)) GiB" >&2
    exit 75
  fi
}

verify_source_version() {
  local version_file="$SOURCE_DIR/chrome/VERSION"
  if [[ ! -f "$version_file" ]]; then
    echo "Chromium source is missing chrome/VERSION." >&2
    exit 66
  fi
  local actual_version
  actual_version="$(
    awk -F= '
      $1 == "MAJOR" { major=$2 }
      $1 == "MINOR" { minor=$2 }
      $1 == "BUILD" { build=$2 }
      $1 == "PATCH" { patch=$2 }
      END {
        if (major == "" || minor == "" || build == "" || patch == "") {
          exit 2
        }
        print major "." minor "." build "." patch
      }
    ' "$version_file"
  )" || {
    echo "Chromium source chrome/VERSION is incomplete." >&2
    exit 66
  }
  if [[ "$actual_version" != "$EXPECTED_CHROMIUM_VERSION" ]]; then
    echo "Chromium source version mismatch." >&2
    echo "  expected: $EXPECTED_CHROMIUM_VERSION" >&2
    echo "  actual:   $actual_version" >&2
    exit 65
  fi
}

prepare_source() {
  if [[ -f "$SOURCE_STAMP" ]]; then
    [[ -f "$SOURCE_DIR/chrome/browser/ui/browser.cc" ]] || {
      echo "Source stamp exists but Chromium source is incomplete." >&2
      exit 66
    }
    if ! grep -Fxq \
      "chromium=$EXPECTED_CHROMIUM_VERSION" \
      "$SOURCE_STAMP"; then
      echo "Build root source stamp belongs to a different Chromium version." >&2
      echo "Use a new build root for $EXPECTED_CHROMIUM_VERSION." >&2
      exit 65
    fi
    verify_source_version
    return
  fi

  require_free_space 55

  "$BUILD_ROOT/retrieve_and_unpack_resource.sh" -d -g arm64
  "$TOOLS_DIR/bin/python3" \
    "$BUILD_ROOT/ungoogled-chromium/utils/prune_binaries.py" \
    "$SOURCE_DIR" \
    "$BUILD_ROOT/ungoogled-chromium/pruning.list"
  "$TOOLS_DIR/bin/python3" \
    "$BUILD_ROOT/ungoogled-chromium/utils/patches.py" \
    apply \
    "$SOURCE_DIR" \
    "$BUILD_ROOT/ungoogled-chromium/patches" \
    "$BUILD_ROOT/patches"
  "$TOOLS_DIR/bin/python3" \
    "$BUILD_ROOT/ungoogled-chromium/utils/domain_substitution.py" \
    apply \
    -r "$BUILD_ROOT/ungoogled-chromium/domain_regex.list" \
    -f "$BUILD_ROOT/ungoogled-chromium/domain_substitution.list" \
    "$SOURCE_DIR"
  verify_source_version

  printf '%s\n' \
    "chromium=$EXPECTED_CHROMIUM_VERSION" \
    "architecture=arm64" \
    "patches=applied" \
    "domains=substituted" \
    > "$SOURCE_STAMP"
}

prepare_toolchain() {
  if [[ -f "$TOOLCHAIN_STAMP" &&
        -x "$SOURCE_DIR/third_party/llvm-build/Release+Asserts/bin/clang" &&
        -x "$SOURCE_DIR/third_party/rust-toolchain/bin/rustc" &&
        -x "$SOURCE_DIR/third_party/node/mac_arm64/node-darwin-arm64/bin/node" ]]
  then
    return
  fi

  require_free_space 42
  "$BUILD_ROOT/retrieve_and_unpack_resource.sh" -p arm64

  "$SOURCE_DIR/third_party/llvm-build/Release+Asserts/bin/clang" \
    --version >/dev/null
  "$SOURCE_DIR/third_party/rust-toolchain/bin/rustc" \
    --version >/dev/null
  "$SOURCE_DIR/third_party/node/mac_arm64/node-darwin-arm64/bin/node" \
    --version >/dev/null

  printf '%s\n' "architecture=arm64" "toolchain=verified" \
    > "$TOOLCHAIN_STAMP"
}

require_metal_toolchain() {
  if [[ -n "${NEANTIK_METAL_TOOLCHAIN_PATH:-}" ]]; then
    "$SCRIPT_DIR/verify-metal-toolchain.sh" \
      "$NEANTIK_METAL_TOOLCHAIN_PATH" >/dev/null
  fi
  if ! xcrun --find metallib >/dev/null 2>&1 ||
     ! xcrun metal --version >/dev/null 2>&1
  then
    echo "Xcode's optional Metal Toolchain is not installed." >&2
    echo "Install it once in a normal user Terminal:" >&2
    echo "  xcodebuild -downloadComponent MetalToolchain" >&2
    echo "Then verify it with:" >&2
    echo "  xcrun --find metallib" >&2
    exit 69
  fi
}

validate_gpu_mode() {
  case "${NEANTIK_NO_METAL:-0}" in
    0|1) ;;
    *)
      echo "NEANTIK_NO_METAL must be 0 or 1." >&2
      exit 64
      ;;
  esac
}

configure_build() {
  prepare_source
  local expected_overlay_sha256
  local actual_overlay_sha256
  expected_overlay_sha256="$(
    plutil -extract nevisionOverlay.scriptSHA256 raw -o - \
      "$PROJECT_ROOT/runtime/fingerprint-chromium.lock.json"
  )"
  actual_overlay_sha256="$(
    shasum -a 256 "$SCRIPT_DIR/apply-runtime-overlay.py" |
      awk '{print $1}'
  )"
  if [[ "$actual_overlay_sha256" != "$expected_overlay_sha256" ]]; then
    echo "NeAntik runtime overlay does not match the source lock." >&2
    exit 65
  fi
  "$TOOLS_DIR/bin/python3" \
    "$SCRIPT_DIR/apply-runtime-overlay.py" \
    "$SOURCE_DIR"
  local expected_device_tuple_overlay_sha256
  local actual_device_tuple_overlay_sha256
  expected_device_tuple_overlay_sha256="$(
    plutil -extract nevisionDeviceTuples.scriptSHA256 raw -o - \
      "$PROJECT_ROOT/runtime/fingerprint-chromium.lock.json"
  )"
  actual_device_tuple_overlay_sha256="$(
    shasum -a 256 "$SCRIPT_DIR/apply-runtime-device-tuples.py" |
      awk '{print $1}'
  )"
  if [[ "$actual_device_tuple_overlay_sha256" != \
        "$expected_device_tuple_overlay_sha256" ]]; then
    echo "NeAntik device-tuple overlay does not match the source lock." >&2
    exit 65
  fi
  "$TOOLS_DIR/bin/python3" \
    "$SCRIPT_DIR/apply-runtime-device-tuples.py" \
    "$SOURCE_DIR"
  "$TOOLS_DIR/bin/python3" \
    "$SCRIPT_DIR/apply-runtime-branding-overlay.py" \
    "$SOURCE_DIR"
  prepare_toolchain
  validate_gpu_mode
  if [[ "${NEANTIK_NO_METAL:-0}" != "1" ]]; then
    require_metal_toolchain
  fi
  require_free_space 5

  mkdir -p "$SOURCE_DIR/out/Default"
  awk '
    /^symbol_level=1$/ { print "symbol_level=0"; next }
    { print }
  ' \
    "$BUILD_ROOT/ungoogled-chromium/flags.gn" \
    "$BUILD_ROOT/flags.macos.gn" \
    > "$SOURCE_DIR/out/Default/args.gn"
  printf '%s\n' 'target_cpu = "arm64"' \
    >> "$SOURCE_DIR/out/Default/args.gn"
  if [[ "${NEANTIK_NO_METAL:-0}" == "1" ]]; then
    printf '%s\n' 'angle_enable_metal = false' \
      >> "$SOURCE_DIR/out/Default/args.gn"
  else
    printf '%s\n' 'angle_enable_metal = true' \
      >> "$SOURCE_DIR/out/Default/args.gn"
  fi

  if [[ ! -x "$SOURCE_DIR/out/Default/gn" ]]; then
    (
      cd "$SOURCE_DIR"
      ./tools/gn/bootstrap/bootstrap.py \
        -o out/Default/gn \
        --skip-generate-buildfiles
    )
  fi

  if [[ ! -x "$SOURCE_DIR/third_party/rust-toolchain/bin/bindgen" ]]; then
    (
      cd "$SOURCE_DIR"
      ./tools/rust/build_bindgen.py --skip-test
    )
  fi

  (
    cd "$SOURCE_DIR"
    ./out/Default/gn gen out/Default --fail-on-unused-args
  )

  printf '%s\n' \
    "architecture=arm64" \
    "symbol_level=0" \
    "no_metal=${NEANTIK_NO_METAL:-0}" \
    "metal_toolchain=${NEANTIK_METAL_TOOLCHAIN_PATH:-system-xcrun}" \
    "gn=generated" \
    > "$CONFIG_STAMP"
}

build_runtime() {
  configure_build
  if [[ -x "$SOURCE_DIR/out/Default/NeAntik Browser.app/Contents/MacOS/NeAntik Browser" ]]
  then
    require_free_space 12
  else
    require_free_space 25
  fi

  local jobs="${NEANTIK_NINJA_JOBS:-4}"
  if [[ ! "$jobs" =~ ^[1-9][0-9]*$ ]] || (( jobs > 12 )); then
    echo "NEANTIK_NINJA_JOBS must be an integer from 1 through 12." >&2
    exit 64
  fi

  (
    set -o pipefail
    cd "$SOURCE_DIR"
    NINJA_STATUS='[%f/%t %es %r jobs] ' \
      ninja -C out/Default -j"$jobs" chrome chromedriver 2>&1 |
      tee -a "$BUILD_LOG"
  )
}

case "$PHASE" in
  prepare)
    prepare_source
    prepare_toolchain
    ;;
  configure)
    configure_build
    ;;
  build|all)
    build_runtime
    ;;
esac

echo
echo "NeAntik runtime phase completed: $PHASE"
echo "Build root: $BUILD_ROOT"
