#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOCK_FILE="$SCRIPT_DIR/../runtime/fingerprint-chromium.lock.json"
SOURCE_CONTRACT="$SCRIPT_DIR/../runtime/chromium-152-source-contract.json"

if [[ -f "$SOURCE_CONTRACT" ]]; then
  echo "Legacy source-lock verification is blocked for the owned Chromium rebase." >&2
  echo "Use scripts/export-runtime-source-provenance.py and scripts/verify-runtime-source-provenance.py with the owned rebase source root." >&2
  exit 65
fi

if [[ $# -ne 1 || -z "${1:-}" ]]; then
  echo "Usage: $0 /absolute/path/to/nevision-chromium-build" >&2
  exit 64
fi

ROOT="$1"
FINGERPRINT_ROOT="$ROOT/ungoogled-chromium"

if [[ ! -d "$ROOT/.git" || ! -d "$FINGERPRINT_ROOT/.git" ]]; then
  echo "Expected a macOS packaging checkout with an ungoogled-chromium checkout." >&2
  exit 66
fi

read_lock() {
  plutil -extract "$1" raw -o - "$LOCK_FILE"
}

sha256_object() {
  local repository="$1"
  local object="$2"
  git -C "$repository" show "$object" | shasum -a 256 | awk '{print $1}'
}

expect_equal() {
  local label="$1"
  local actual="$2"
  local expected="$3"
  if [[ "$actual" != "$expected" ]]; then
    echo "FAIL $label" >&2
    echo "  expected: $expected" >&2
    echo "  actual:   $actual" >&2
    exit 65
  fi
  echo "OK   $label"
}

MAC_COMMIT="$(read_lock macPackaging.commit)"
FINGERPRINT_COMMIT="$(read_lock fingerprintChromium.commit)"

expect_equal \
  "NeAntik deterministic-hash overlay" \
  "$(shasum -a 256 "$SCRIPT_DIR/apply-runtime-overlay.py" | awk '{print $1}')" \
  "$(read_lock nevisionOverlay.scriptSHA256)"
expect_equal \
  "NeAntik coherent-device-tuple overlay" \
  "$(shasum -a 256 "$SCRIPT_DIR/apply-runtime-device-tuples.py" | awk '{print $1}')" \
  "$(read_lock nevisionDeviceTuples.scriptSHA256)"
expect_equal \
  "NeAntik source-branding overlay" \
  "$(shasum -a 256 "$SCRIPT_DIR/apply-runtime-branding-overlay.py" | awk '{print $1}')" \
  "$(read_lock nevisionBranding.scriptSHA256)"

expect_equal \
  "macOS packaging commit" \
  "$(git -C "$ROOT" rev-parse HEAD)" \
  "$MAC_COMMIT"
expect_equal \
  "macOS packaging tree" \
  "$(git -C "$ROOT" rev-parse 'HEAD^{tree}')" \
  "$(read_lock macPackaging.tree)"
expect_equal \
  "macOS packaging license" \
  "$(sha256_object "$ROOT" HEAD:LICENSE)" \
  "$(read_lock macPackaging.licenseSHA256)"
expect_equal \
  "macOS patch series" \
  "$(sha256_object "$ROOT" HEAD:patches/series)" \
  "$(read_lock macPackaging.patchSeriesSHA256)"
expect_equal \
  "macOS GN flags" \
  "$(sha256_object "$ROOT" HEAD:flags.macos.gn)" \
  "$(read_lock macPackaging.flagsSHA256)"
expect_equal \
  "macOS ARM64 resources" \
  "$(sha256_object "$ROOT" HEAD:downloads-arm64.ini)" \
  "$(read_lock macPackaging.arm64DownloadsSHA256)"

expect_equal \
  "fingerprint Chromium commit" \
  "$(git -C "$FINGERPRINT_ROOT" rev-parse HEAD)" \
  "$FINGERPRINT_COMMIT"
expect_equal \
  "fingerprint Chromium tree" \
  "$(git -C "$FINGERPRINT_ROOT" rev-parse 'HEAD^{tree}')" \
  "$(read_lock fingerprintChromium.tree)"
expect_equal \
  "fingerprint Chromium version" \
  "$(git -C "$FINGERPRINT_ROOT" show HEAD:chromium_version.txt | tr -d '\r\n')" \
  "$(read_lock fingerprintChromium.chromiumVersion)"
expect_equal \
  "fingerprint Chromium license" \
  "$(sha256_object "$FINGERPRINT_ROOT" HEAD:LICENSE)" \
  "$(read_lock fingerprintChromium.licenseSHA256)"
expect_equal \
  "fingerprint patch series" \
  "$(sha256_object "$FINGERPRINT_ROOT" HEAD:patches/series)" \
  "$(read_lock fingerprintChromium.patchSeriesSHA256)"
expect_equal \
  "fingerprint patch tree" \
  "$(git -C "$FINGERPRINT_ROOT" rev-parse HEAD:patches/extra/fingerprint)" \
  "$(read_lock fingerprintChromium.fingerprintPatchTree)"
expect_equal \
  "fingerprint GN flags" \
  "$(sha256_object "$FINGERPRINT_ROOT" HEAD:flags.gn)" \
  "$(read_lock fingerprintChromium.flagsSHA256)"
expect_equal \
  "fingerprint downloads manifest" \
  "$(sha256_object "$FINGERPRINT_ROOT" HEAD:downloads.ini)" \
  "$(read_lock fingerprintChromium.downloadsSHA256)"
expect_equal \
  "fingerprint pruning manifest" \
  "$(sha256_object "$FINGERPRINT_ROOT" HEAD:pruning.list)" \
  "$(read_lock fingerprintChromium.pruningSHA256)"

if ! git -C "$ROOT" show HEAD:build.sh | grep -Fq 'target_cpu = "arm64"'; then
  echo "FAIL macOS build script has no ARM64 target." >&2
  exit 65
fi
echo "OK   macOS build script declares ARM64"

FINGERPRINT_STATUS="$(
  git -C "$FINGERPRINT_ROOT" status \
    --porcelain=v1 \
    --untracked-files=all
)"
if [[ -n "$FINGERPRINT_STATUS" ]]; then
  echo "FAIL fingerprint checkout contains local or untracked changes." >&2
  echo "$FINGERPRINT_STATUS" >&2
  exit 65
fi
echo "OK   fingerprint checkout is clean"

MAC_STATUS="$(
  git -C "$ROOT" status \
    --porcelain=v1 \
    --untracked-files=all
)"
MAC_UNEXPECTED="$(
  printf '%s\n' "$MAC_STATUS" |
    grep -v '^ M ungoogled-chromium$' || true
)"
if [[ -n "$MAC_UNEXPECTED" ]]; then
  echo "FAIL macOS packaging checkout contains unexpected changes." >&2
  echo "$MAC_UNEXPECTED" >&2
  exit 65
fi
if ! printf '%s\n' "$MAC_STATUS" |
    grep -qx ' M ungoogled-chromium'; then
  echo "FAIL pinned fingerprint submodule replacement is missing." >&2
  exit 65
fi
echo "OK   macOS packaging checkout only replaces the pinned submodule"

echo
echo "Source lock verified. This does not prove that patches apply or Chromium builds."
