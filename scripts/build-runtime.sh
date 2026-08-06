#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TOOLS_PATH="$SCRIPT_DIR/runtime-tools"
REBASE_PLAN="$PROJECT_ROOT/runtime/chromium-151-rebase-plan.json"
TOOLCHAIN_LOCK="$PROJECT_ROOT/runtime/chromium-151-toolchain-lock.json"

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

REBASE_MAC_COMMIT="$(
  plutil -extract macPackaging.commit raw -o - "$REBASE_PLAN"
)"
REBASE_COMMON_COMMIT="$(
  plutil -extract commonChromium.commit raw -o - "$REBASE_PLAN"
)"
ACTUAL_MAC_COMMIT="$(git -C "$BUILD_ROOT" rev-parse HEAD)"
ACTUAL_COMMON_COMMIT="$(
  git -C "$BUILD_ROOT/ungoogled-chromium" rev-parse HEAD
)"
if [[ "$ACTUAL_MAC_COMMIT" == "$REBASE_MAC_COMMIT" ||
      "$ACTUAL_COMMON_COMMIT" == "$REBASE_COMMON_COMMIT" ]]; then
  if [[ "$ACTUAL_MAC_COMMIT" != "$REBASE_MAC_COMMIT" ||
        "$ACTUAL_COMMON_COMMIT" != "$REBASE_COMMON_COMMIT" ]]; then
    echo "Chromium rebase source pair is only partially pinned." >&2
    exit 65
  fi
  SOURCE_MODE="owned-rebase"
  python3 "$SCRIPT_DIR/preflight-runtime-rebase-150.py" \
    "$BUILD_ROOT" \
    --plan "$REBASE_PLAN"
  python3 "$SCRIPT_DIR/verify-nevision-patchset-manifest.py" \
    --rebase-plan "$REBASE_PLAN" \
    --source-evidence \
    --release
else
  SOURCE_MODE="legacy-lock"
  "$SCRIPT_DIR/verify-runtime-source.sh" "$BUILD_ROOT"
fi

BUILD_DIR="$BUILD_ROOT/build"
SOURCE_DIR="$BUILD_DIR/src"
CACHE_DIR="$BUILD_DIR/download_cache"
TOOLS_DIR="$BUILD_DIR/nevision-tools"
PIP_CACHE_DIR="$BUILD_DIR/pip-cache"
PYTHON_CACHE_DIR="$BUILD_DIR/pycache"
GO_CACHE_DIR="$BUILD_DIR/go-build-cache"
GO_PATH_DIR="$BUILD_DIR/go-path"
SOURCE_STAMP="$BUILD_DIR/.nevision-source-ready-v1"
TOOLCHAIN_STAMP="$BUILD_DIR/.nevision-toolchain-ready-v1"
CONFIG_STAMP="$BUILD_DIR/.nevision-config-ready-v1"
BUILD_LOG="$BUILD_DIR/nevision-runtime-arm64.log"
SOURCE_PROVENANCE="$BUILD_DIR/source-provenance.json"
CANDIDATE_LOCK="$BUILD_DIR/runtime-candidate-lock.json"
if [[ "$SOURCE_MODE" == "owned-rebase" ]]; then
  EXPECTED_CHROMIUM_VERSION="$(
    plutil -extract targetChromiumVersion raw -o - "$REBASE_PLAN"
  )"
  PATCH_MANIFEST_SHA256="$(
    shasum -a 256 \
      "$PROJECT_ROOT/runtime/nevision-patches/series.json" |
      awk '{print $1}'
  )"
else
  EXPECTED_CHROMIUM_VERSION="$(
    plutil -extract fingerprintChromium.chromiumVersion raw -o - \
      "$PROJECT_ROOT/runtime/fingerprint-chromium.lock.json"
  )"
fi

mkdir -p \
  "$BUILD_DIR" \
  "$CACHE_DIR" \
  "$PIP_CACHE_DIR" \
  "$PYTHON_CACHE_DIR" \
  "$GO_CACHE_DIR" \
  "$GO_PATH_DIR"

if [[ ! -x "$TOOLS_DIR/bin/python3" ]]; then
  python3 -m venv "$TOOLS_DIR"
fi

export PIP_CACHE_DIR
export PYTHONPYCACHEPREFIX="$PYTHON_CACHE_DIR"
export GOCACHE="$GO_CACHE_DIR"
export GOPATH="$GO_PATH_DIR"
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

write_owned_source_stamp() {
  printf '%s\n' \
    "chromium=$EXPECTED_CHROMIUM_VERSION" \
    "architecture=arm64" \
    "source_mode=$SOURCE_MODE" \
    "patch_manifest_sha256=$PATCH_MANIFEST_SHA256" \
    "patches=applied" \
    "domains=substituted" \
    > "$SOURCE_STAMP"
}

apply_owned_source_layers() {
  local recover_incremental="${1:-0}"
  if [[ "$recover_incremental" == "1" ]]; then
    "$TOOLS_DIR/bin/python3" \
      "$SCRIPT_DIR/apply-neantik-patchset.py" \
      "$SOURCE_DIR" \
      --rebase-plan "$REBASE_PLAN" \
      --recover-incremental
  elif [[ "$recover_incremental" != "0" ]]; then
    echo "Internal error: invalid incremental recovery mode." >&2
    exit 70
  else
    "$TOOLS_DIR/bin/python3" \
      "$SCRIPT_DIR/apply-neantik-patchset.py" \
      "$SOURCE_DIR" \
      --rebase-plan "$REBASE_PLAN"
  fi
  "$TOOLS_DIR/bin/python3" \
    "$SCRIPT_DIR/apply-owned-runtime-device-tuples.py" \
    "$SOURCE_DIR"
  "$TOOLS_DIR/bin/python3" \
    "$SCRIPT_DIR/apply-owned-runtime-device-tuples.py" \
    "$SOURCE_DIR" \
    --check
  "$TOOLS_DIR/bin/python3" \
    "$SCRIPT_DIR/verify-chromium-webrtc-policy.py" \
    "$SOURCE_DIR"
  "$TOOLS_DIR/bin/python3" \
    "$SCRIPT_DIR/verify-chromium-launch-flags.py" \
    "$SOURCE_DIR"
}

prepare_source_version_override() {
  if [[ "$SOURCE_MODE" != "owned-rebase" ]]; then
    return
  fi
  local version_file="$BUILD_ROOT/ungoogled-chromium/chromium_version.txt"
  local expected_from
  local expected_to
  local current
  expected_from="$(
    plutil -extract sourceVersionOverride.from raw -o - "$REBASE_PLAN"
  )"
  expected_to="$(
    plutil -extract sourceVersionOverride.to raw -o - "$REBASE_PLAN"
  )"
  current="$(tr -d '\r\n' < "$version_file")"
  if [[ "$expected_to" != "$EXPECTED_CHROMIUM_VERSION" ]]; then
    echo "Chromium source-version override does not match the rebase target." >&2
    exit 65
  fi
  if [[ "$current" == "$expected_from" ]]; then
    printf '%s\n' "$expected_to" > "$version_file"
  elif [[ "$current" != "$expected_to" ]]; then
    echo "Chromium packaging version file has an unexpected value." >&2
    echo "  expected original: $expected_from" >&2
    echo "  expected target:   $expected_to" >&2
    echo "  actual:            $current" >&2
    exit 65
  fi
  if [[ "$(tr -d '\r\n' < "$version_file")" != "$expected_to" ]]; then
    echo "Chromium source-version override was not applied exactly." >&2
    exit 65
  fi
}

prepare_source() {
  case "${NEANTIK_RECOVER_SOURCE_STAMP:-0}" in
    0|1) ;;
    *)
      echo "NEANTIK_RECOVER_SOURCE_STAMP must be 0 or 1." >&2
      exit 64
      ;;
  esac
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
    if ! grep -Fxq "source_mode=$SOURCE_MODE" "$SOURCE_STAMP"; then
      echo "Build root source stamp belongs to a different source mode." >&2
      exit 65
    fi
    if [[ "$SOURCE_MODE" == "owned-rebase" ]] &&
       ! grep -Fxq \
         "patch_manifest_sha256=$PATCH_MANIFEST_SHA256" \
         "$SOURCE_STAMP"
    then
      if [[ "${NEANTIK_RECOVER_SOURCE_STAMP:-0}" != "1" ]]; then
        echo "Build root source stamp belongs to a different owned patch manifest." >&2
        echo "Set NEANTIK_RECOVER_SOURCE_STAMP=1 only after intentionally updating the owned patchset." >&2
        exit 65
      fi
      verify_source_version
      apply_owned_source_layers 1
      write_owned_source_stamp
      echo "Recovered verified Chromium source stamp after an intentional patch-manifest update."
      return
    fi
    verify_source_version
    if [[ "$SOURCE_MODE" == "owned-rebase" ]]; then
      apply_owned_source_layers
    fi
    return
  fi

  if [[ "${NEANTIK_RECOVER_SOURCE_STAMP:-0}" == "1" ]]; then
    if [[ "$SOURCE_MODE" != "owned-rebase" ]]; then
      echo "Source-stamp recovery is supported only for the owned Chromium rebase." >&2
      exit 65
    fi
    verify_source_version
    apply_owned_source_layers 1
    write_owned_source_stamp
    echo "Recovered verified Chromium source stamp after interrupted prepare."
    return
  fi

  require_free_space 55

  prepare_source_version_override
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
  if [[ "$SOURCE_MODE" == "owned-rebase" ]]; then
    apply_owned_source_layers
  fi

  printf '%s\n' \
    "chromium=$EXPECTED_CHROMIUM_VERSION" \
    "architecture=arm64" \
    "source_mode=$SOURCE_MODE" \
    ${PATCH_MANIFEST_SHA256:+"patch_manifest_sha256=$PATCH_MANIFEST_SHA256"} \
    "patches=applied" \
    "domains=substituted" \
    > "$SOURCE_STAMP"
}

verify_owned_rust_archive() {
  if [[ "$SOURCE_MODE" == "owned-rebase" ]]; then
    local rust_filename
    local expected_rust_sha256
    local expected_rust_size
    local rust_archive
    local actual_rust_sha256
    local actual_rust_size
    rust_filename="$(
      plutil -extract rust.filename raw -o - "$TOOLCHAIN_LOCK"
    )"
    expected_rust_sha256="$(
      plutil -extract rust.sha256 raw -o - "$TOOLCHAIN_LOCK"
    )"
    expected_rust_size="$(
      plutil -extract rust.size raw -o - "$TOOLCHAIN_LOCK"
    )"
    rust_archive="$CACHE_DIR/$rust_filename"
    if [[ ! -f "$rust_archive" ]]; then
      echo "Locked Rust toolchain archive is missing: $rust_archive" >&2
      exit 66
    fi
    actual_rust_sha256="$(
      shasum -a 256 "$rust_archive" | awk '{print $1}'
    )"
    actual_rust_size="$(stat -f '%z' "$rust_archive")"
    if [[ "$actual_rust_sha256" != "$expected_rust_sha256" ||
          "$actual_rust_size" != "$expected_rust_size" ]]; then
      echo "Rust toolchain archive does not match NeAntik's lock." >&2
      echo "  expected SHA-256: $expected_rust_sha256" >&2
      echo "  actual SHA-256:   $actual_rust_sha256" >&2
      echo "  expected size:    $expected_rust_size" >&2
      echo "  actual size:      $actual_rust_size" >&2
      exit 65
    fi
    echo "Locked Rust toolchain archive verified."
  fi
}

prepare_owned_dawn_go() {
  if [[ "$SOURCE_MODE" != "owned-rebase" ]]; then
    return
  fi

  local go_root
  local go_binary
  local cipd_binary
  local cipd_partial
  local package
  local instance_id
  local client_revision
  local expected_client_sha256
  local actual_client_sha256
  local expected_go_version
  local actual_go_version
  local expected_deps_version

  go_root="$SOURCE_DIR/third_party/dawn/tools/golang/mac-arm64"
  go_binary="$go_root/bin/go"
  cipd_binary="$TOOLS_DIR/cipd"
  cipd_partial="$TOOLS_DIR/cipd.partial"
  package="$(plutil -extract dawnGo.package raw -o - "$TOOLCHAIN_LOCK")"
  instance_id="$(
    plutil -extract dawnGo.instanceId raw -o - "$TOOLCHAIN_LOCK"
  )"
  client_revision="$(
    plutil -extract dawnGo.clientRevision raw -o - "$TOOLCHAIN_LOCK"
  )"
  expected_client_sha256="$(
    plutil -extract dawnGo.clientSHA256 raw -o - "$TOOLCHAIN_LOCK"
  )"
  expected_go_version="$(
    plutil -extract dawnGo.version raw -o - "$TOOLCHAIN_LOCK"
  )"
  expected_deps_version="$(
    plutil -extract dawnGo.depsVersion raw -o - "$TOOLCHAIN_LOCK"
  )"

  if ! grep -Fq "'dawn_go_version': '$expected_deps_version'" \
    "$SOURCE_DIR/third_party/dawn/DEPS"
  then
    echo "Dawn Go version does not match NeAntik's toolchain lock." >&2
    exit 65
  fi

  if [[ ! -x "$cipd_binary" ]]; then
    curl -fsSL \
      "https://chrome-infra-packages.appspot.com/client?platform=mac-arm64&version=$client_revision" \
      -o "$cipd_partial"
    actual_client_sha256="$(
      shasum -a 256 "$cipd_partial" | awk '{print $1}'
    )"
    if [[ "$actual_client_sha256" != "$expected_client_sha256" ]]; then
      echo "CIPD client does not match NeAntik's toolchain lock." >&2
      rm -f "$cipd_partial"
      exit 65
    fi
    chmod 0755 "$cipd_partial"
    mv "$cipd_partial" "$cipd_binary"
  else
    actual_client_sha256="$(
      shasum -a 256 "$cipd_binary" | awk '{print $1}'
    )"
    if [[ "$actual_client_sha256" != "$expected_client_sha256" ]]; then
      echo "Cached CIPD client does not match NeAntik's toolchain lock." >&2
      exit 65
    fi
  fi

  printf '%s %s\n' "$package" "$instance_id" |
    "$cipd_binary" ensure -root "$go_root" -ensure-file -

  actual_go_version="$("$go_binary" version)"
  if [[ "$actual_go_version" != \
        "go version go${expected_go_version} darwin/arm64" ]]
  then
    echo "Dawn Go binary does not match NeAntik's toolchain lock." >&2
    exit 65
  fi
  echo "Locked Dawn Go toolchain verified."
}

prepare_toolchain() {
  if [[ -f "$TOOLCHAIN_STAMP" &&
        -x "$SOURCE_DIR/third_party/llvm-build/Release+Asserts/bin/clang" &&
        -x "$SOURCE_DIR/third_party/rust-toolchain/bin/rustc" &&
        -x "$SOURCE_DIR/third_party/node/mac_arm64/node-darwin-arm64/bin/node" ]]
  then
    verify_owned_rust_archive
    prepare_owned_dawn_go
    return
  fi

  require_free_space 42
  "$BUILD_ROOT/retrieve_and_unpack_resource.sh" -p arm64
  verify_owned_rust_archive

  "$SOURCE_DIR/third_party/llvm-build/Release+Asserts/bin/clang" \
    --version >/dev/null
  "$SOURCE_DIR/third_party/rust-toolchain/bin/rustc" \
    --version >/dev/null
  "$SOURCE_DIR/third_party/node/mac_arm64/node-darwin-arm64/bin/node" \
    --version >/dev/null
  prepare_owned_dawn_go

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
  if [[ "$SOURCE_MODE" == "owned-rebase" ]]; then
    apply_owned_source_layers
  else
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
  fi
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

  if [[ "$SOURCE_MODE" == "owned-rebase" ]]; then
    python3 "$SCRIPT_DIR/export-runtime-source-provenance.py" \
      "$SOURCE_DIR" \
      --output "$SOURCE_PROVENANCE"
    python3 "$SCRIPT_DIR/verify-runtime-source-provenance.py" \
      "$SOURCE_PROVENANCE" \
      --source-root "$SOURCE_DIR"
    python3 "$SCRIPT_DIR/export-runtime-candidate-lock.py" \
      "$SOURCE_PROVENANCE" \
      --output "$CANDIDATE_LOCK"
    python3 "$SCRIPT_DIR/verify-runtime-candidate-lock.py" \
      "$CANDIDATE_LOCK" \
      "$SOURCE_PROVENANCE"
  fi

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

  if [[ -s "$BUILD_LOG" ]]; then
    local previous_build_log
    previous_build_log="$BUILD_LOG.$(date -u '+%Y%m%dT%H%M%SZ').$$.previous"
    mv "$BUILD_LOG" "$previous_build_log"
    echo "Previous build log preserved: $previous_build_log"
  fi
  : > "$BUILD_LOG"
  echo "Current build log: $BUILD_LOG"

  (
    set -o pipefail
    cd "$SOURCE_DIR"
    NINJA_STATUS='[%f/%t %es %r jobs] ' \
      ninja -C out/Default -j"$jobs" chrome 2>&1 |
      tee "$BUILD_LOG"
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
if [[ -f "$CANDIDATE_LOCK" ]]; then
  echo "Candidate lock: $CANDIDATE_LOCK"
fi
