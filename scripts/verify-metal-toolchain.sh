#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TOOLS_PATH="$SCRIPT_DIR/runtime-tools"
TOOLCHAIN="${1:-${NEANTIK_METAL_TOOLCHAIN_PATH:-}}"

if [[ -z "$TOOLCHAIN" || "$TOOLCHAIN" != /* || ! -d "$TOOLCHAIN" ]]; then
  echo "Usage: $0 /absolute/path/to/Metal.xctoolchain" >&2
  exit 64
fi

INFO_PLIST="$TOOLCHAIN/ToolchainInfo.plist"
METAL="$TOOLCHAIN/usr/bin/metal"
METALLIB="$TOOLCHAIN/usr/bin/metallib"
if [[ ! -f "$INFO_PLIST" || ! -x "$METAL" || ! -x "$METALLIB" ]]; then
  echo "Metal toolchain structure is incomplete." >&2
  exit 66
fi

IDENTIFIER="$(plutil -extract Identifier raw -o - "$INFO_PLIST")"
if [[ "$IDENTIFIER" != com.apple.dt.toolchain.Metal.* ]]; then
  echo "Unexpected Metal toolchain identifier: $IDENTIFIER" >&2
  exit 65
fi

codesign --verify --strict --verbose=2 "$METAL"
codesign --verify --strict --verbose=2 "$METALLIB"
if ! file "$METAL" | grep -q 'arm64'; then
  echo "Metal compiler does not support Apple Silicon." >&2
  exit 65
fi
if ! file "$METALLIB" | grep -q 'arm64'; then
  echo "Metallib linker does not support Apple Silicon." >&2
  exit 65
fi

SMOKE_SOURCE="$PROJECT_ROOT/Tests/Fixtures/neantik-metal-smoke.metal"
SMOKE_ROOT="$(mktemp -d -t neantik-metal-smoke)"
trap 'rm -rf "$SMOKE_ROOT"' EXIT
export NEANTIK_METAL_TOOLCHAIN_PATH="$TOOLCHAIN"
export NEANTIK_METAL_MODULE_CACHE_PATH="$SMOKE_ROOT/module-cache"
export PATH="$TOOLS_PATH:$PATH"

if [[ "$(xcrun --find metal)" != "$METAL" ||
      "$(xcrun --find metallib)" != "$METALLIB" ]]; then
  echo "NeAntik xcrun wrapper did not select the isolated toolchain." >&2
  exit 65
fi

xcrun metal \
  -c "$SMOKE_SOURCE" \
  -o "$SMOKE_ROOT/neantik-metal-smoke.air" \
  --std=macos-metal2.1 \
  -mmacosx-version-min=10.14
xcrun metallib \
  "$SMOKE_ROOT/neantik-metal-smoke.air" \
  -o "$SMOKE_ROOT/neantik-metal-smoke.metallib"

if ! file "$SMOKE_ROOT/neantik-metal-smoke.air" |
  grep -q 'LLVM bitcode'; then
  echo "Metal smoke output is not AIR bitcode." >&2
  exit 65
fi
if ! file "$SMOKE_ROOT/neantik-metal-smoke.metallib" |
  grep -q 'MetalLib'; then
  echo "Metallib smoke output is not a Metal library." >&2
  exit 65
fi

VERSION="$("$METAL" --version | head -n 1)"
printf '%s\n' \
  "Metal toolchain verified." \
  "Identifier: $IDENTIFIER" \
  "Version:    $VERSION" \
  "Compiler:   $METAL" \
  "Linker:     $METALLIB"
