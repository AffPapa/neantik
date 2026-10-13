#!/bin/zsh

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROBE_SOURCE="$PROJECT_DIR/scripts/fixtures/swift-sdk-compatibility.swift"
PROBE_ROOT="$(mktemp -d "${TMPDIR:-/private/tmp}/neantik-toolchain-probe.XXXXXXXX")"
trap 'rm -rf "$PROBE_ROOT"' EXIT

report_toolchain() {
  if [[ "${NEANTIK_DEVELOPER_DIR_DIAGNOSTICS:-0}" == "1" ]]; then
    print -r -- "$1" >&2
  fi
}

toolchain_is_compatible() {
  local developer_dir="$1"
  local swiftc_path
  local sdk_path
  local sdk_interface
  local compiler_signature
  local sdk_signature
  local compiler_version

  [[ -d "$developer_dir" ]] || { report_toolchain "Xcode candidate absent: $developer_dir"; return 1; }
  swiftc_path="$(
    DEVELOPER_DIR="$developer_dir" xcrun --find swiftc 2>/dev/null
  )" || { report_toolchain "Cannot locate Swift compiler: $developer_dir"; return 1; }
  sdk_path="$(
    DEVELOPER_DIR="$developer_dir" \
      xcrun --sdk macosx --show-sdk-path 2>/dev/null
  )" || { report_toolchain "Cannot locate macOS SDK: $developer_dir"; return 1; }
  sdk_interface="$(
    find "$sdk_path/usr/lib/swift/Swift.swiftmodule" \
      -maxdepth 1 \
      -name 'arm64*-apple-macos.swiftinterface' \
      -print \
      -quit
  )"
  [[ -n "$sdk_interface" ]] || { report_toolchain "No ARM64 Swift interface: $developer_dir"; return 1; }

  compiler_signature="$(
    "$swiftc_path" --version 2>/dev/null |
      sed -n 's/.*(\(swiftlang-[^)]*\)).*/\1/p'
  )"
  compiler_version="$("$swiftc_path" --version 2>/dev/null | sed -n 's/.*Swift version \([0-9]*\)\.\([0-9]*\).*/\1 \2/p' | head -n 1)"
  local major="${compiler_version%% *}" minor="${compiler_version#* }"
  [[ "$major" == <-> && "$minor" == <-> ]] || return 1
  (( major > 6 || (major == 6 && minor >= 2) )) || {
    report_toolchain "Swift 6.2 or newer required by Package.swift: $developer_dir"
    return 1
  }
  sdk_signature="$(
    sed -n \
      's@// swift-compiler-version:.*(\(swiftlang-[^)]*\)).*@\1@p' \
      "$sdk_interface" |
      head -n 1
  )"
  report_toolchain "Xcode candidate: $developer_dir; compiler=$compiler_signature; SDK=$sdk_signature"
  [[ -n "$compiler_signature" && -n "$sdk_signature" ]] || return 1
  # Stable SDK modules may be built by an older compiler. Build identifiers
  # are provenance, not a compatibility test. Import and typecheck the APIs
  # used by our manager against this exact compiler/SDK, without linking or
  # executing a program. An explicitly pinned failing Xcode never falls back.
  mkdir -p "$PROBE_ROOT/module-cache"
  if DEVELOPER_DIR="$developer_dir" "$swiftc_path" -typecheck \
      -sdk "$sdk_path" -target arm64-apple-macosx14.0 -swift-version 5 \
      -module-cache-path "$PROBE_ROOT/module-cache" "$PROBE_SOURCE" \
      >"$PROBE_ROOT/probe.log" 2>&1; then
    report_toolchain "SDK API typecheck passed: $developer_dir"
    return 0
  fi
  report_toolchain "SDK API typecheck failed: $developer_dir"
  if [[ "${NEANTIK_DEVELOPER_DIR_DIAGNOSTICS:-0}" == "1" ]]; then
    head -c 4096 "$PROBE_ROOT/probe.log" >&2
  fi
  return 1
}

typeset -a developer_candidates
if [[ -n "${DEVELOPER_DIR:-}" ]]; then
  developer_candidates=("$DEVELOPER_DIR")
else
  developer_candidates=(
    "$(xcode-select -p 2>/dev/null || true)"
    "/Applications/Xcode.app/Contents/Developer"
    "/Applications/Xcode-beta.app/Contents/Developer"
  )
  # Hosted macOS runners retain versioned Xcode bundles. Keep the selected
  # installation first and retain the same compiler/SDK compatibility gate.
  developer_candidates+=(/Applications/Xcode_*.app/Contents/Developer(N))
fi

for candidate in "${developer_candidates[@]}"; do
  if [[ -n "$candidate" ]] && toolchain_is_compatible "$candidate"; then
    print -r -- "$candidate"
    exit 0
  fi
done

echo \
  "No Xcode developer directory passed the manager's Swift/SDK API typecheck." \
  >&2
exit 69
