#!/bin/zsh

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

usage() {
  echo "Usage: $0 /absolute/path/to/NeAntik\\ Browser.app /absolute/path/to/NeAntik\\ Browser\\ Packaging /absolute/output/NeAntik\\ Browser.app" >&2
}

if [[ $# -ne 3 ]]; then
  usage
  exit 64
fi

INPUT_APP="$1"
PACKAGING_DIR="$2"
OUTPUT_APP="$3"
SIGNING_IDENTITY="${NEANTIK_SIGNING_IDENTITY:?Set a signing identity name or SHA-1}"
DEVELOPMENT="${NEANTIK_RUNTIME_SIGNING_DEVELOPMENT:-0}"

for input in "$INPUT_APP" "$PACKAGING_DIR"; do
  if [[ "$input" != /* ]]; then
    echo "Signing inputs must be existing absolute directories: $input" >&2
    exit 66
  fi
  if [[ -L "$input" ]]; then
    echo "Signing input must not be a symlink: $input" >&2
    exit 66
  fi
done
if [[ ! -d "$INPUT_APP" ||
      -L "$INPUT_APP/Contents" ||
      -L "$INPUT_APP/Contents/Resources" ]]; then
  echo "Signing inputs must be existing absolute directories: $INPUT_APP" >&2
  exit 66
fi
if [[ "$OUTPUT_APP" != /* || -e "$OUTPUT_APP" ]]; then
  echo "Output must be an absolute path that does not exist." >&2
  exit 64
fi
if [[ "$DEVELOPMENT" != "0" && "$DEVELOPMENT" != "1" ]]; then
  echo "NEANTIK_RUNTIME_SIGNING_DEVELOPMENT must be 0 or 1." >&2
  exit 64
fi

INPUT_PLIST="$INPUT_APP/Contents/Info.plist"
RUNTIME_VERSION="$(
  plutil -extract CFBundleShortVersionString raw -o - "$INPUT_PLIST"
)"
for expectation in \
  "CFBundleExecutable:NeAntik Browser" \
  "CFBundleIdentifier:app.neantik.runtime" \
  "NeAntikRuntimeFlavor:fingerprint-chromium"; do
  key="${expectation%%:*}"
  expected="${expectation#*:}"
  actual="$(plutil -extract "$key" raw -o - "$INPUT_PLIST")"
  if [[ "$actual" != "$expected" ]]; then
    echo "Unexpected runtime $key: $actual" >&2
    exit 65
  fi
done
BUILD_MODE="$(plutil -extract NeAntikRuntimeBuildMode raw -o - "$INPUT_PLIST")"
if [[ "$BUILD_MODE" != "source-build" && "$BUILD_MODE" != "metal-integration" ]]; then
  echo "Unexpected runtime NeAntikRuntimeBuildMode: $BUILD_MODE" >&2
  exit 65
fi

apply_public_runtime_icon() {
  local app_path="$1"
  local project_icon="$PROJECT_DIR/Resources/NeAntik.icns"
  local runtime_resources="$app_path/Contents/Resources"
  local runtime_icon="$runtime_resources/app.icns"
  local temporary_icon=""

  if [[ ! -f "$project_icon" || -L "$project_icon" ||
        ! -d "$runtime_resources" || -L "$runtime_resources" ||
        -L "$runtime_icon" ||
        (-e "$runtime_icon" && ! -f "$runtime_icon") ]]; then
    echo "Runtime icon inputs are unsafe or incomplete." >&2
    exit 66
  fi
  temporary_icon="$(
    /usr/bin/mktemp "$runtime_resources/.neantik-runtime-icon.XXXXXX"
  )"
  /bin/cp "$project_icon" "$temporary_icon"
  if [[ ! -f "$temporary_icon" || -L "$temporary_icon" ]] ||
      ! cmp -s "$project_icon" "$temporary_icon"; then
    echo "Runtime icon overlay verification failed." >&2
    exit 65
  fi
  /bin/mv -f "$temporary_icon" "$runtime_icon"
  if [[ ! -f "$runtime_icon" || -L "$runtime_icon" ]] ||
      ! cmp -s "$project_icon" "$runtime_icon"; then
    echo "Runtime icon overlay verification failed." >&2
    exit 65
  fi
}

manual_public_alpha_sign() {
  local entitlements_root="${NEANTIK_CHROMIUM_SOURCE_ROOT:-}"
  local app_entitlements=""
  local helper_gpu_entitlements=""
  local helper_renderer_entitlements=""
  if [[ -n "$entitlements_root" ]]; then
    app_entitlements="$entitlements_root/chrome/app/app-entitlements.plist"
    helper_gpu_entitlements="$entitlements_root/chrome/app/helper-gpu-entitlements.plist"
    helper_renderer_entitlements="$entitlements_root/chrome/app/helper-renderer-entitlements.plist"
  fi
  for entitlements in \
    "$app_entitlements" \
    "$helper_gpu_entitlements" \
    "$helper_renderer_entitlements"; do
    if [[ ! -f "$entitlements" ]]; then
      echo "Manual public-alpha runtime signing needs NEANTIK_CHROMIUM_SOURCE_ROOT with Chromium entitlements." >&2
      exit 66
    fi
  done

  sign_code() {
    local target="$1"
    local entitlements="${2:-}"
    local args=(
      --force
      --options runtime
      --timestamp
      --sign "$SIGNING_IDENTITY"
    )
    if [[ -n "$entitlements" ]]; then
      args+=(--entitlements "$entitlements")
    fi
    codesign "${args[@]}" "$target"
  }

  helper_entitlements_for_bundle() {
    local helper_name="$1"
    case "$helper_name" in
      *" Browser Helper (GPU).app")
        printf '%s\n' "$helper_gpu_entitlements"
        ;;
      *" Browser Helper (Renderer).app")
        printf '%s\n' "$helper_renderer_entitlements"
        ;;
      *)
        printf '\n'
        ;;
    esac
  }

  require_developer_id_timestamp() {
    local target="$1"
    local details=""
    details="$(codesign -dv --verbose=4 "$target" 2>&1)"
    if ! grep -q '^Authority=Developer ID Application:' <<<"$details"; then
      echo "Runtime code is not signed by a Developer ID Application identity: $target" >&2
      exit 65
    fi
    if ! grep -q '^Timestamp=' <<<"$details"; then
      echo "Runtime code signature has no trusted timestamp: $target" >&2
      exit 65
    fi
  }

  if [[ -e "$OUTPUT_APP" ]]; then
    echo "Output already exists: $OUTPUT_APP" >&2
    exit 66
  fi

  ditto "$INPUT_APP" "$OUTPUT_APP"
  apply_public_runtime_icon "$OUTPUT_APP"

  find "$OUTPUT_APP/Contents" -type f -print0 |
  while IFS= read -r -d '' candidate; do
    if file -b "$candidate" | grep -q 'Mach-O'; then
      sign_code "$candidate"
    fi
  done

  find "$OUTPUT_APP/Contents" -type d -name '*.app' -print0 |
  while IFS= read -r -d '' nested_app; do
    entitlements="$(helper_entitlements_for_bundle "$(basename "$nested_app")")"
    sign_code "$nested_app" "$entitlements"
  done

  find "$OUTPUT_APP/Contents" -type d -name '*.framework' -print0 |
  while IFS= read -r -d '' framework; do
    sign_code "$framework"
  done

  sign_code "$OUTPUT_APP" "$app_entitlements"
  if ! CODESIGN_VERIFY_OUTPUT="$(
    codesign --verify --deep --strict --verbose=2 "$OUTPUT_APP" 2>&1
  )"; then
    printf '%s\n' "$CODESIGN_VERIFY_OUTPUT" >&2
    exit 65
  fi
  SIGNATURE_DETAILS="$(codesign -dv --verbose=4 "$OUTPUT_APP" 2>&1)"
  if ! grep -q '^Authority=Developer ID Application:' \
      <<<"$SIGNATURE_DETAILS"; then
    echo "Runtime is not signed by a Developer ID Application identity." >&2
    exit 65
  fi
  if ! grep -q '^Timestamp=' <<<"$SIGNATURE_DETAILS"; then
    echo "Runtime signature has no trusted timestamp." >&2
    exit 65
  fi
  for library_name in \
    libEGL.dylib \
    libGLESv2.dylib \
    libvk_swiftshader.dylib; do
    nested_library="$(
      find "$OUTPUT_APP/Contents/Frameworks" -type f \
        -name "$library_name" -print -quit
    )"
    if [[ -f "$nested_library" ]]; then
      require_developer_id_timestamp "$nested_library"
    fi
  done
  echo "$OUTPUT_APP"
}

if [[ ! -d "$PACKAGING_DIR" ]]; then
  if [[ "${NEANTIK_RELEASE_CHANNEL:-}" == "public-alpha" ]]; then
    echo "Chromium signing package is missing; using manual public-alpha Developer ID runtime signing." >&2
    manual_public_alpha_sign
    exit 0
  fi
  echo "Signing inputs must be existing absolute directories: $PACKAGING_DIR" >&2
  exit 66
fi

SIGNER="$PACKAGING_DIR/sign_chrome.py"
BUILD_CONFIG="$PACKAGING_DIR/signing/build_props_config.py"
if [[ ! -f "$SIGNER" || ! -f "$BUILD_CONFIG" ]]; then
  echo "Chromium signing package is incomplete." >&2
  exit 66
fi
for expected_source_line in \
  "return 'NeAntik Browser'" \
  "return '$RUNTIME_VERSION'" \
  "return 'app.neantik.runtime'"; do
  if ! grep -Fq "$expected_source_line" "$BUILD_CONFIG"; then
    echo "Chromium signing config does not match the runtime: $expected_source_line" >&2
    exit 65
  fi
done

STAGING="$(mktemp -d -t nevision-runtime-signing-input)"
SIGNED_ROOT="$(mktemp -d -t nevision-runtime-signing-output)"
cleanup() {
  rm -rf "$STAGING" "$SIGNED_ROOT"
}
trap cleanup EXIT

ditto "$INPUT_APP" "$STAGING/NeAntik Browser.app"
ditto "$PACKAGING_DIR" "$STAGING/NeAntik Browser Packaging"
STAGED_APP="$STAGING/NeAntik Browser.app"
apply_public_runtime_icon "$STAGED_APP"

# Chromium's release signer refuses an already attached signature. Work only
# on the temporary copy and preserve the verified build artifact unchanged.
find "$STAGED_APP" -type d \
  \( -name '*.app' -o -name '*.framework' \) -print0 |
while IFS= read -r -d '' bundle; do
  codesign --remove-signature "$bundle" 2>/dev/null || true
done
find "$STAGED_APP/Contents" -type f -print0 |
while IFS= read -r -d '' candidate; do
  file_description="$(file -b "$candidate")"
  if [[ "$file_description" == *Mach-O* ]]; then
    codesign --remove-signature "$candidate" 2>/dev/null || true
  fi
done
while IFS= read -r signature_dir; do
  [[ "$signature_dir" == "$STAGED_APP"/*/_CodeSignature ]]
  find "$signature_dir" -depth -delete
done < <(find "$STAGED_APP" -type d -name _CodeSignature -print)

if codesign -dv "$STAGED_APP" >/dev/null 2>&1 ||
    find "$STAGED_APP" -type d -name _CodeSignature -print -quit |
      grep -q .; then
  echo "Temporary Chromium input still contains an attached signature." >&2
  exit 65
fi

SIGN_ARGUMENTS=(
  --input "$STAGING"
  --output "$SIGNED_ROOT"
  --identity "$SIGNING_IDENTITY"
  --disable-packaging
)
if [[ "$DEVELOPMENT" == "1" ]]; then
  SIGN_ARGUMENTS+=(--development)
fi
python3 "$STAGING/NeAntik Browser Packaging/sign_chrome.py" \
  "${SIGN_ARGUMENTS[@]}"

SIGNED_APP="$SIGNED_ROOT/stable/NeAntik Browser.app"
if [[ ! -d "$SIGNED_APP" ]]; then
  echo "Chromium signing pipeline did not produce NeAntik Browser.app." >&2
  exit 65
fi

mkdir -p "$(dirname "$OUTPUT_APP")"
ditto "$SIGNED_APP" "$OUTPUT_APP"
if ! CODESIGN_VERIFY_OUTPUT="$(
  codesign --verify --deep --strict --verbose=2 "$OUTPUT_APP" 2>&1
)"; then
  printf '%s\n' "$CODESIGN_VERIFY_OUTPUT" >&2
  exit 65
fi

if [[ "$DEVELOPMENT" == "0" ]]; then
  SIGNATURE_DETAILS="$(codesign -dv --verbose=4 "$OUTPUT_APP" 2>&1)"
  if ! grep -q '^Authority=Developer ID Application:' \
      <<<"$SIGNATURE_DETAILS"; then
    echo "Runtime is not signed by a Developer ID Application identity." >&2
    exit 65
  fi
  if ! grep -q '^Timestamp=' <<<"$SIGNATURE_DETAILS"; then
    echo "Runtime signature has no trusted timestamp." >&2
    exit 65
  fi
fi

for helper in \
  "NeAntik Browser Helper (Renderer).app" \
  "NeAntik Browser Helper (GPU).app"; do
  helper_path="$(
    find "$OUTPUT_APP" -type d -name "$helper" -print -quit
  )"
  entitlements="$(codesign -d --entitlements :- "$helper_path" 2>/dev/null)"
  if ! grep -q 'com.apple.security.cs.allow-jit' <<<"$entitlements"; then
    echo "$helper is missing the Chromium JIT entitlement." >&2
    exit 65
  fi
done

echo "$OUTPUT_APP"
