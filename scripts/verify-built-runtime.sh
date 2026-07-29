#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOCK_FILE="$SCRIPT_DIR/../runtime/fingerprint-chromium.lock.json"

usage() {
  echo "Usage: $0 /absolute/path/to/Chromium.app [report.json] [args.gn]" >&2
}

if [[ $# -lt 1 || $# -gt 3 || -z "${1:-}" ]]; then
  usage
  exit 64
fi

APP_PATH="$1"
REPORT_PATH="${2:-}"
BUILD_ARGS_PATH="${3:-}"

if [[ "$APP_PATH" != /* || ! -d "$APP_PATH" ]]; then
  echo "Chromium.app must be an existing absolute path." >&2
  exit 66
fi

INFO_PLIST="$APP_PATH/Contents/Info.plist"
if [[ ! -f "$INFO_PLIST" ]]; then
  echo "Chromium bundle has no Info.plist." >&2
  exit 66
fi

GPU_MODE="unrecorded"
BUILD_ARGS_SHA256=""
if [[ -n "$BUILD_ARGS_PATH" ]]; then
  if [[ "$BUILD_ARGS_PATH" != /* || ! -f "$BUILD_ARGS_PATH" ]]; then
    echo "args.gn must be an existing absolute path." >&2
    exit 66
  fi
  if ! grep -Eq \
    '^[[:space:]]*target_cpu[[:space:]]*=[[:space:]]*"arm64"[[:space:]]*$' \
    "$BUILD_ARGS_PATH"
  then
    echo "args.gn does not declare target_cpu = \"arm64\"." >&2
    exit 65
  fi
  METAL_TRUE_COUNT="$(
    grep -Ec \
      '^[[:space:]]*angle_enable_metal[[:space:]]*=[[:space:]]*true[[:space:]]*$' \
      "$BUILD_ARGS_PATH" || true
  )"
  METAL_FALSE_COUNT="$(
    grep -Ec \
      '^[[:space:]]*angle_enable_metal[[:space:]]*=[[:space:]]*false[[:space:]]*$' \
      "$BUILD_ARGS_PATH" || true
  )"
  if (( METAL_TRUE_COUNT == 1 && METAL_FALSE_COUNT == 0 )); then
    GPU_MODE="metal"
  elif (( METAL_FALSE_COUNT == 1 && METAL_TRUE_COUNT == 0 )); then
    GPU_MODE="no-metal"
  else
    echo "args.gn must explicitly declare angle_enable_metal exactly once." >&2
    exit 65
  fi
  BUILD_ARGS_SHA256="$(
    shasum -a 256 "$BUILD_ARGS_PATH" | awk '{print $1}'
  )"
fi

EXPECTED_VERSION="$(
  plutil -extract fingerprintChromium.chromiumVersion raw -o - "$LOCK_FILE"
)"
SOURCE_LOCK_SHA256="$(
  shasum -a 256 "$LOCK_FILE" | awk '{print $1}'
)"
OVERLAY_SHA256="$(
  plutil -extract nevisionOverlay.scriptSHA256 raw -o - "$LOCK_FILE"
)"
DEVICE_TUPLE_OVERLAY_SHA256="$(
  plutil -extract nevisionDeviceTuples.scriptSHA256 raw -o - "$LOCK_FILE"
)"
EXECUTABLE_NAME="$(
  plutil -extract CFBundleExecutable raw -o - "$INFO_PLIST"
)"
EXECUTABLE_PATH="$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME"

if [[ ! -x "$EXECUTABLE_PATH" ]]; then
  echo "Chromium bundle executable is missing or not executable." >&2
  exit 66
fi

ACTUAL_VERSION="$(
  plutil -extract CFBundleShortVersionString raw -o - "$INFO_PLIST" \
    2>/dev/null ||
  plutil -extract CFBundleVersion raw -o - "$INFO_PLIST"
)"
if [[ "$ACTUAL_VERSION" != "$EXPECTED_VERSION" ]]; then
  echo "Chromium version mismatch." >&2
  echo "Expected: $EXPECTED_VERSION" >&2
  echo "Actual:   $ACTUAL_VERSION" >&2
  exit 65
fi

MAIN_ARCHITECTURES="$(lipo -archs "$EXECUTABLE_PATH")"
if [[ "$MAIN_ARCHITECTURES" != "arm64" ]]; then
  echo "Main Chromium executable is not ARM64-only: $MAIN_ARCHITECTURES" >&2
  exit 65
fi

MACHO_LIST="$(mktemp "${TMPDIR:-/tmp}/nevision-machos.XXXXXX")"
trap 'rm -f "$MACHO_LIST"' EXIT

find "$APP_PATH/Contents" -type f \
  \( -perm -111 -o -name '*.dylib' \) -print0 |
while IFS= read -r -d '' candidate; do
  if file -b "$candidate" | grep -q 'Mach-O'; then
    printf '%s\n' "$candidate"
  fi
done > "$MACHO_LIST"

MACHO_COUNT=0
while IFS= read -r binary; do
  [[ -n "$binary" ]] || continue
  MACHO_COUNT=$((MACHO_COUNT + 1))
  architectures="$(lipo -archs "$binary")"
  if [[ "$architectures" != "arm64" ]]; then
    echo "Non-ARM64 nested code: $binary ($architectures)" >&2
    exit 65
  fi
done < "$MACHO_LIST"

if (( MACHO_COUNT == 0 )); then
  echo "No Mach-O code found in Chromium bundle." >&2
  exit 65
fi

if ! CODESIGN_VERIFY_OUTPUT="$(
  codesign --verify --deep --strict --verbose=2 "$APP_PATH" 2>&1
)"; then
  printf '%s\n' "$CODESIGN_VERIFY_OUTPUT" >&2
  exit 65
fi
SIGNATURE_DETAILS="$(codesign -dv --verbose=4 "$APP_PATH" 2>&1)"
if grep -q '^Signature=adhoc$' <<< "$SIGNATURE_DETAILS"; then
  SIGNATURE_KIND="ad-hoc"
elif grep -q '^Authority=Developer ID Application:' \
  <<< "$SIGNATURE_DETAILS"
then
  SIGNATURE_KIND="developer-id"
elif grep -q '^Authority=' <<< "$SIGNATURE_DETAILS"; then
  SIGNATURE_KIND="identity"
else
  SIGNATURE_KIND="unclassified"
fi

FRAMEWORK_BINARY="$(
  find "$APP_PATH/Contents/Frameworks" -type f \
    -name '* Framework' -print -quit
)"
if [[ -z "$FRAMEWORK_BINARY" ]]; then
  echo "Chromium-compatible Framework binary was not found." >&2
  exit 66
fi

for protocol_string in \
  "fingerprint-platform" \
  "fingerprint-timezone" \
  "fingerprint-locale" \
  "apple-device-tuple"
do
  if ! grep -aFq "$protocol_string" "$FRAMEWORK_BINARY"; then
    echo "Missing fingerprint protocol string: $protocol_string" >&2
    exit 65
  fi
done

if [[ -n "$BUILD_ARGS_PATH" ]]; then
  SOURCE_ROOT="$(cd "$(dirname "$BUILD_ARGS_PATH")/../.." && pwd -P)"
  SERIES_FILE="$SCRIPT_DIR/../runtime/nevision-patches/series.json"
  if [[ -f "$SOURCE_ROOT/components/ungoogled/BUILD.gn" ]]; then
    if [[ ! -f "$SERIES_FILE" ]]; then
      echo "NeAntik patch series manifest is missing: $SERIES_FILE" >&2
      exit 66
    fi
    SOURCE_ROOT="$SOURCE_ROOT" SERIES_FILE="$SERIES_FILE" python3 - <<'PY'
import hashlib
import json
import os
import sys
from pathlib import Path

source_root = Path(os.environ["SOURCE_ROOT"])
series_file = Path(os.environ["SERIES_FILE"])
series = json.loads(series_file.read_text(encoding="utf-8"))

checked = 0
for group in series.get("patchGroups", []):
    if not group.get("releaseRequired", False):
        continue
    for relative_path, expected_sha256 in group.get("postimageSHA256", {}).items():
        path = source_root / relative_path
        if not path.is_file():
            print(
                f"Release patch postimage is missing: {relative_path}",
                file=sys.stderr,
            )
            sys.exit(65)
        actual_sha256 = hashlib.sha256(path.read_bytes()).hexdigest()
        if actual_sha256 != expected_sha256:
            print(
                "Release patch postimage hash mismatch: "
                f"{relative_path} expected {expected_sha256} got {actual_sha256}",
                file=sys.stderr,
            )
            sys.exit(65)
        checked += 1

if checked == 0:
    print("No releaseRequired patch postimages were checked.", file=sys.stderr)
    sys.exit(65)
PY
  elif [[ ! -f "$SERIES_FILE" ]]; then
    echo "NeAntik patch series manifest is missing: $SERIES_FILE" >&2
    exit 66
  fi
fi

VERSION_OUTPUT="$("$EXECUTABLE_PATH" --version 2>&1)"
if [[ "$VERSION_OUTPUT" != *"$EXPECTED_VERSION"* ]]; then
  echo "Runtime --version output does not contain $EXPECTED_VERSION." >&2
  echo "$VERSION_OUTPUT" >&2
  exit 65
fi

EXECUTABLE_SHA256="$(shasum -a 256 "$EXECUTABLE_PATH" | awk '{print $1}')"
FRAMEWORK_SHA256="$(shasum -a 256 "$FRAMEWORK_BINARY" | awk '{print $1}')"

if [[ -n "$REPORT_PATH" ]]; then
  if [[ "$REPORT_PATH" != /* ]]; then
    echo "Report path must be absolute." >&2
    exit 64
  fi
  mkdir -p "$(dirname "$REPORT_PATH")"
  REPORT_PATH="$REPORT_PATH" \
  EXPECTED_VERSION="$EXPECTED_VERSION" \
  EXECUTABLE_PATH="$EXECUTABLE_PATH" \
  EXECUTABLE_SHA256="$EXECUTABLE_SHA256" \
  FRAMEWORK_PATH="$FRAMEWORK_BINARY" \
  FRAMEWORK_SHA256="$FRAMEWORK_SHA256" \
  MACHO_COUNT="$MACHO_COUNT" \
  SIGNATURE_KIND="$SIGNATURE_KIND" \
  GPU_MODE="$GPU_MODE" \
  SOURCE_LOCK_SHA256="$SOURCE_LOCK_SHA256" \
  OVERLAY_SHA256="$OVERLAY_SHA256" \
  DEVICE_TUPLE_OVERLAY_SHA256="$DEVICE_TUPLE_OVERLAY_SHA256" \
  BUILD_ARGS_PATH="$BUILD_ARGS_PATH" \
  BUILD_ARGS_SHA256="$BUILD_ARGS_SHA256" \
  python3 - <<'PY'
import datetime
import json
import os
from pathlib import Path

report = {
    "schemaVersion": 1,
    "createdAt": datetime.datetime.now(
        datetime.timezone.utc
    ).isoformat().replace("+00:00", "Z"),
    "chromiumVersion": os.environ["EXPECTED_VERSION"],
    "architecture": "arm64",
    "gpuMode": os.environ["GPU_MODE"],
    "sourceLockSHA256": os.environ["SOURCE_LOCK_SHA256"],
    "nevisionOverlaySHA256": os.environ["OVERLAY_SHA256"],
    "nevisionDeviceTupleOverlaySHA256":
        os.environ["DEVICE_TUPLE_OVERLAY_SHA256"],
    "machoCount": int(os.environ["MACHO_COUNT"]),
    "executable": {
        "path": os.environ["EXECUTABLE_PATH"],
        "sha256": os.environ["EXECUTABLE_SHA256"],
    },
    "framework": {
        "path": os.environ["FRAMEWORK_PATH"],
        "sha256": os.environ["FRAMEWORK_SHA256"],
    },
    "codeSignature": "verified",
    "codeSignatureKind": os.environ["SIGNATURE_KIND"],
    "fingerprintProtocolStrings": "verified",
}
if os.environ["BUILD_ARGS_PATH"]:
    report["buildArguments"] = {
        "path": os.environ["BUILD_ARGS_PATH"],
        "sha256": os.environ["BUILD_ARGS_SHA256"],
    }
Path(os.environ["REPORT_PATH"]).write_text(
    json.dumps(report, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY
  chmod 600 "$REPORT_PATH"
fi

echo "Built NeAntik Chromium runtime verified."
echo "Version:    $EXPECTED_VERSION"
echo "GPU mode:   $GPU_MODE"
echo "Signature:  $SIGNATURE_KIND"
echo "Mach-O:    $MACHO_COUNT ARM64-only files"
echo "Executable: $EXECUTABLE_SHA256"
echo "Framework:  $FRAMEWORK_SHA256"
if [[ -n "$REPORT_PATH" ]]; then
  echo "Report:     $REPORT_PATH"
fi
