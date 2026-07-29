#!/bin/bash

set -uo pipefail
umask 077

PACKAGE_DIR="$(cd "$(dirname "$0")" && pwd)"
AUDITOR="$PACKAGE_DIR/NeAntikRuntimeAudit"
REPORT_VERIFIER="$PACKAGE_DIR/verify-gui-fingerprint-report.py"
RUNTIME_LOCK="$PACKAGE_DIR/evidence/fingerprint-chromium.lock.json"
REPORT="$PACKAGE_DIR/fingerprint-audit.json"
LOG="$PACKAGE_DIR/fingerprint-audit-terminal.log"

pause_before_close() {
  if [[ -t 0 ]]; then
    read -r -p "Press Return to close." || true
  fi
}

fail_before_run() {
  local message="$1"
  local status="${2:-66}"
  echo "$message"
  pause_before_close
  exit "$status"
}

resolve_runtime() {
  local app="$1"
  [[ -d "$app" && ! -L "$app" ]] || return 1
  local plist="$app/Contents/Info.plist"
  [[ -f "$plist" && ! -L "$plist" ]] || return 1
  local executable_name
  executable_name="$(
    plutil -extract CFBundleExecutable raw -o - "$plist" 2>/dev/null
  )" || return 1
  [[ "$executable_name" == "NeAntik Browser" ]] || return 1
  local executable="$app/Contents/MacOS/$executable_name"
  [[ -x "$executable" && ! -L "$executable" ]] || return 1
  printf '%s\n' "$executable"
}

RUNTIME="$(resolve_runtime "$PACKAGE_DIR/NeAntik Browser.app" || true)"

[[ -n "$RUNTIME" ]] ||
  fail_before_run "The package is missing a valid NeAntik Browser.app."
[[ -x "$AUDITOR" && ! -L "$AUDITOR" ]] ||
  fail_before_run "The package is missing the NeAntikRuntimeAudit executable."
[[ -f "$REPORT_VERIFIER" && ! -L "$REPORT_VERIFIER" ]] ||
  fail_before_run "The package is missing verify-gui-fingerprint-report.py."
[[ -f "$RUNTIME_LOCK" && ! -L "$RUNTIME_LOCK" ]] ||
  fail_before_run "The package is missing its pinned runtime lock."

# A failed new run must never verify or preserve a stale report from an older
# browser/runtime pair.
rm -f "$REPORT" "$LOG"

echo "NeAntik Chromium A -> B -> A audit"
echo "Runtime: $RUNTIME"
echo "Report:  $REPORT"
echo "Log:     $LOG"
echo

{
  "$AUDITOR" "$RUNTIME" "$REPORT"
  audit_status=$?
  if (( audit_status != 0 )); then
    echo
    echo "The browser audit failed; independent verification was not run."
    exit "$audit_status"
  fi
  if [[ ! -f "$REPORT" || -L "$REPORT" ]]; then
    echo
    echo "The browser audit did not produce a safe fingerprint report."
    exit 66
  fi

  echo
  echo "Independent production GUI report verification:"
  python3 "$REPORT_VERIFIER" \
    "$REPORT" \
    --runtime-lock "$RUNTIME_LOCK"
} 2>&1 | tee "$LOG"
pipeline_status=("${PIPESTATUS[@]}")
status=${pipeline_status[0]}
log_status=${pipeline_status[1]}
if (( log_status != 0 )); then
  echo "FAIL: could not preserve fingerprint-audit-terminal.log." >&2
  if (( status == 0 )); then
    status=74
  fi
fi

echo
if (( status == 0 )); then
  echo "PASS: the runtime produced a production-qualified A -> B -> A report."
  echo "Keep fingerprint-audit.json and fingerprint-audit-terminal.log."
else
  echo "FAIL: inspect fingerprint-audit-terminal.log and the preserved"
  echo "diagnostics path printed above."
fi
echo
pause_before_close
exit "$status"
