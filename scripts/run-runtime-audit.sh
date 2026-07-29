#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="${NEANTIK_AUDIT_BUILD_DIR:-/private/tmp/nevision-runtime-audit-cli}"
EXECUTABLE="$BUILD_DIR/NeAntikRuntimeAudit"

if [[ ( $# -ne 2 && $# -ne 3 ) || "$1" != /* || "$2" != /* ]]; then
  echo "Usage: $0 /absolute/path/to/Chromium /absolute/path/to/report.json [--headless-single-process-diagnostic]" >&2
  exit 64
fi
if [[ $# -eq 3 && "$3" != "--headless-single-process-diagnostic" ]]; then
  echo "Unknown audit option: $3" >&2
  exit 64
fi

mkdir -p "$BUILD_DIR/module-cache"

"$SCRIPT_DIR/build-runtime-audit-cli.sh" "$EXECUTABLE" >/dev/null

exec "$EXECUTABLE" "$@"
