#!/bin/zsh

set -euo pipefail

toolchain_is_compatible() {
  local developer_dir="$1"
  local swiftc_path
  local sdk_path
  local sdk_interface
  local compiler_signature
  local sdk_signature

  [[ -d "$developer_dir" ]] || return 1
  swiftc_path="$(
    DEVELOPER_DIR="$developer_dir" xcrun --find swiftc 2>/dev/null
  )" || return 1
  sdk_path="$(
    DEVELOPER_DIR="$developer_dir" \
      xcrun --sdk macosx --show-sdk-path 2>/dev/null
  )" || return 1
  sdk_interface="$(
    find "$sdk_path/usr/lib/swift/Swift.swiftmodule" \
      -maxdepth 1 \
      -name 'arm64*-apple-macos.swiftinterface' \
      -print \
      -quit
  )"
  [[ -n "$sdk_interface" ]] || return 1

  compiler_signature="$(
    "$swiftc_path" --version 2>/dev/null |
      sed -n 's/.*(\(swiftlang-[^)]*\)).*/\1/p'
  )"
  sdk_signature="$(
    sed -n \
      's@// swift-compiler-version:.*(\(swiftlang-[^)]*\)).*@\1@p' \
      "$sdk_interface" |
      head -n 1
  )"
  [[
    -n "$compiler_signature" &&
    "$compiler_signature" == "$sdk_signature"
  ]]
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
fi

for candidate in "${developer_candidates[@]}"; do
  if [[ -n "$candidate" ]] && toolchain_is_compatible "$candidate"; then
    print -r -- "$candidate"
    exit 0
  fi
done

echo \
  "No compatible Xcode developer directory has matching Swift compiler and macOS SDK builds." \
  >&2
exit 69
