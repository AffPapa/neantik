#!/bin/bash
# Run only as a workflow on a fresh disposable GitHub-hosted macOS VM.
set -Eeuo pipefail
umask 077
if [[ "${GITHUB_ACTIONS:-}" != true || "${RUNNER_ENVIRONMENT:-}" != github-hosted || "$(id -un)" != runner || "${RUNNER_TEMP:-}" != /Users/runner/* ]]; then
  printf '%s\n' 'fixture refused: disposable GitHub-hosted runner required' >&2
  exit 77
fi
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
work=$(mktemp -d "$RUNNER_TEMP/neantik-keychain-ci-XXXXXXXX" 2>/dev/null) || { printf '%s\n' '{"event":"setupFailed","status":1}'; exit 1; }
if ! /usr/bin/clang -fobjc-arc -Werror -Wno-deprecated-declarations -framework Foundation -framework Security "$root/fixture.m" -o "$work/OwnerA" > "$work/compile.log" 2>&1; then
  printf '%s\n' '{"event":"compileFailed","status":1}'
  exit 1
fi
if ! cp -p "$work/OwnerA" "$work/OwnerB" > "$work/copy.log" 2>&1; then
  printf '%s\n' '{"event":"copyFailed","status":1}'
  exit 1
fi
/usr/bin/codesign --force --sign - --identifier synthetic.neantik.ownerA "$work/OwnerA" > "$work/sign-a.log" 2>&1
/usr/bin/codesign --force --sign - --identifier synthetic.neantik.ownerB "$work/OwnerB" > "$work/sign-b.log" 2>&1
/usr/bin/codesign --verify --strict "$work/OwnerA" > /dev/null 2>&1
/usr/bin/codesign --verify --strict "$work/OwnerB" > /dev/null 2>&1
/usr/bin/codesign -d --verbose=4 "$work/OwnerA" > "$work/inspect-a.log" 2>&1
/usr/bin/codesign -d --verbose=4 "$work/OwnerB" > "$work/inspect-b.log" 2>&1
/usr/bin/grep -Fqx 'Identifier=synthetic.neantik.ownerA' "$work/inspect-a.log"
/usr/bin/grep -Fqx 'Identifier=synthetic.neantik.ownerB' "$work/inspect-b.log"
/usr/bin/grep -Fqx 'Signature=adhoc' "$work/inspect-a.log"
/usr/bin/grep -Fqx 'Signature=adhoc' "$work/inspect-b.log"
printf '%s\n' '{"event":"signatures","differentIdentifiers":true,"adHoc":true}'
python3 "$root/supervise.py" "$work" 2> "$work/supervisor-error.log"
# Leave the fake keychain to VM teardown. Do not modify the search list or call
# SecKeychainDelete as a cleanup step; even on CI, that would add another effect.
