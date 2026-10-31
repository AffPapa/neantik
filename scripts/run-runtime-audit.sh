#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="${NEANTIK_AUDIT_BUILD_DIR:-/private/tmp/nevision-runtime-audit-cli}"
EXECUTABLE="$BUILD_DIR/NeAntikRuntimeAudit"

if [[ ( $# -lt 2 || $# -gt 4 ) || "$1" != /* || "$2" != /* ]]; then
  echo "Usage: $0 /absolute/path/to/Chromium /absolute/path/to/report.json [--headless-single-process-diagnostic | --manager-app /absolute/path/to/NeAntik.app]" >&2
  exit 64
fi
case "$#" in
  2)
    ;;
  3)
    if [[ "$3" != "--headless-single-process-diagnostic" ]]; then
      echo "Unknown audit option: $3" >&2
      exit 64
    fi
    ;;
  4)
    if [[ "$3" != "--manager-app" || "$4" != /* || "$4" != *.app ]]; then
      echo "Expected --manager-app followed by an absolute NeAntik.app path." >&2
      exit 64
    fi
    ;;
esac

mkdir -p "$BUILD_DIR/module-cache"

"$SCRIPT_DIR/build-runtime-audit-cli.sh" "$EXECUTABLE" >/dev/null

exec "$EXECUTABLE" "$@"
