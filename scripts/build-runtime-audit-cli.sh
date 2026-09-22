#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ $# -ne 1 || "$1" != /* ]]; then
  echo "Usage: $0 /absolute/path/to/NeAntikRuntimeAudit" >&2
  exit 64
fi

OUTPUT="$1"
BUILD_DIR="$(dirname "$OUTPUT")"
MODULE_CACHE="$BUILD_DIR/module-cache"

# Keep the audit CLI in lockstep with the executable target.  The audit uses
# the same process/profile/runtime policies as the app, and a hand-maintained
# partial source list silently goes stale whenever a new policy type is added.
SOURCE_FILES=()
while IFS= read -r source_file; do
  SOURCE_FILES+=("$source_file")
done < <(
  find "$PROJECT_ROOT/Sources/NeAntik" -maxdepth 1 -type f \
    -name '*.swift' ! -name 'NeAntikApp.swift' -print | sort
)

mkdir -p "$MODULE_CACHE"

swiftc \
  -swift-version 5 \
  -parse-as-library \
  -target arm64-apple-macos14.0 \
  -module-cache-path "$MODULE_CACHE" \
  "${SOURCE_FILES[@]}" \
  "$PROJECT_ROOT/Tools/RuntimeAuditCLI.swift" \
  -framework AppKit \
  -framework Security \
  -framework SwiftUI \
  -framework Network \
  -o "$OUTPUT"

codesign --force --sign - "$OUTPUT"
codesign --verify --strict --verbose=2 "$OUTPUT"

if ! file "$OUTPUT" | grep -q 'Mach-O 64-bit executable arm64'; then
  echo "Runtime audit CLI is not an ARM64 Mach-O executable." >&2
  exit 65
fi

echo "$OUTPUT"
