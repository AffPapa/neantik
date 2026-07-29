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

mkdir -p "$MODULE_CACHE"

swiftc \
  -swift-version 5 \
  -parse-as-library \
  -target arm64-apple-macos14.0 \
  -module-cache-path "$MODULE_CACHE" \
  "$PROJECT_ROOT/Sources/NeAntik/AppPaths.swift" \
  "$PROJECT_ROOT/Sources/NeAntik/Models.swift" \
  "$PROJECT_ROOT/Sources/NeAntik/BrowserProcessManager.swift" \
  "$PROJECT_ROOT/Sources/NeAntik/BrowserRuntimeInspector.swift" \
  "$PROJECT_ROOT/Sources/NeAntik/BrowserRuntimePreflight.swift" \
  "$PROJECT_ROOT/Sources/NeAntik/FingerprintAudit.swift" \
  "$PROJECT_ROOT/Tools/RuntimeAuditCLI.swift" \
  -framework Security \
  -framework Network \
  -o "$OUTPUT"

codesign --force --sign - "$OUTPUT"
codesign --verify --strict --verbose=2 "$OUTPUT"

if ! file "$OUTPUT" | grep -q 'Mach-O 64-bit executable arm64'; then
  echo "Runtime audit CLI is not an ARM64 Mach-O executable." >&2
  exit 65
fi

echo "$OUTPUT"
