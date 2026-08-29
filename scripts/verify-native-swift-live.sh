#!/bin/zsh

set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: $0 manager|fingerprint|all [NeAntik-Dev.app]" >&2
  exit 64
fi

MODE="$1"
case "$MODE" in
  manager|fingerprint|all)
    ;;
  *)
    echo "Unknown live verification mode: $MODE" >&2
    exit 64
    ;;
esac

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${2:-$PROJECT_DIR/.build/neantik-local/NeAntik-Dev.app}"
RUNTIME_EXECUTABLE="$APP_PATH/Contents/Resources/NeAntik Browser.app/Contents/MacOS/NeAntik Browser"

if [[ ! -d "$APP_PATH" || ! -x "$RUNTIME_EXECUTABLE" ]]; then
  echo "Live verification requires a built NeAntik Dev.app with its browser engine: $APP_PATH" >&2
  echo "Build it first with: ./Develop-NeAntik.command --no-open" >&2
  exit 66
fi

export DEVELOPER_DIR="$(
  "$PROJECT_DIR/scripts/resolve-compatible-developer-dir.sh"
)"
LIVE_TEST_ROOT="$(mktemp -d /private/tmp/neantik-swift-live-XXXXXX)"

cleanup() {
  if [[ -n "${LIVE_TEST_ROOT:-}" && "$LIVE_TEST_ROOT" == /private/tmp/neantik-swift-live-* && -d "$LIVE_TEST_ROOT" ]]; then
    rm -rf "$LIVE_TEST_ROOT"
  fi
}
trap cleanup EXIT

mkdir -p \
  "$LIVE_TEST_ROOT/swiftpm-home" \
  "$LIVE_TEST_ROOT/module-cache" \
  "$LIVE_TEST_ROOT/build"

run_live_suite() {
  local suite="$1"
  local opt_in_variable="$2"
  local output="$LIVE_TEST_ROOT/$suite-output.txt"

  echo "Running NeAntik live Swift suite: $suite"
  (
    cd "$PROJECT_DIR"
    /usr/bin/env \
      SWIFTPM_HOME="$LIVE_TEST_ROOT/swiftpm-home" \
      CLANG_MODULE_CACHE_PATH="$LIVE_TEST_ROOT/module-cache" \
      NEANTIK_LIVE_AUDIT_APP="$APP_PATH" \
      "$opt_in_variable=1" \
      swift test \
        --disable-sandbox \
        --scratch-path "$LIVE_TEST_ROOT/build" \
        --filter "$suite"
  ) 2>&1 | tee "$output"

  if ! grep -Eq \
    'Test run with [1-9][0-9]* tests? in [1-9][0-9]* suites? passed' \
    "$output"; then
    echo "Live Swift suite did not execute a positive test count: $suite" >&2
    exit 1
  fi
}

if [[ "$MODE" == manager || "$MODE" == all ]]; then
  run_live_suite \
    LiveBrowserProcessManagerIntegrationTests \
    NEANTIK_RUN_LIVE_BROWSER_MANAGER
fi

if [[ "$MODE" == fingerprint || "$MODE" == all ]]; then
  run_live_suite \
    LiveFingerprintAuditIntegrationTests \
    NEANTIK_RUN_LIVE_FINGERPRINT_AUDIT
fi

echo "NeAntik live verification passed: $MODE"
