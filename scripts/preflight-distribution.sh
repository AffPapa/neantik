#!/bin/zsh

set -u
set -o pipefail

MODE="${1:-direct}"
if [[ "$MODE" != "direct" ]]; then
  echo "Usage: $0 [direct]" >&2
  echo "NeAntik open-source supports Direct Distribution only." >&2
  exit 64
fi

IDENTITIES="$(security find-identity -v -p codesigning 2>&1)"
MISSING=0

pass() {
  printf 'PASS    %s\n' "$1"
}

declared() {
  printf 'READY   %s\n' "$1"
}

missing() {
  printf 'MISSING %s\n' "$1"
  MISSING=$((MISSING + 1))
}

identity_line_for() {
  local identity="$1"
  if [[ "$identity" =~ '^[0-9A-Fa-f]{40}$' ]]; then
    printf '%s\n' "$IDENTITIES" |
      grep -Ei "[[:space:]]${identity}[[:space:]]" |
      head -n 1
  else
    printf '%s\n' "$IDENTITIES" |
      grep -F "\"$identity\"" |
      head -n 1
  fi
}

identity_prefix_is_installed() {
  local prefix="$1"
  printf '%s\n' "$IDENTITIES" | grep -Fq "\"$prefix"
}

identity_matches_prefix() {
  local identity="$1"
  local prefix="$2"
  local identity_line
  identity_line="$(identity_line_for "$identity")"
  [[ "$identity_line" == *"\"$prefix"* ]]
}

echo "Direct distribution"

if identity_prefix_is_installed "Developer ID Application:"; then
  pass "Developer ID Application identity is installed"
else
  missing "Developer ID Application identity"
fi

if [[ -n "${NEANTIK_SIGNING_IDENTITY:-}" ]]; then
  if identity_matches_prefix \
    "$NEANTIK_SIGNING_IDENTITY" \
    "Developer ID Application:"; then
    pass "NEANTIK_SIGNING_IDENTITY resolves to Developer ID Application"
  else
    missing "NEANTIK_SIGNING_IDENTITY does not resolve to Developer ID Application"
  fi
else
  missing "NEANTIK_SIGNING_IDENTITY environment value"
fi

if [[ -n "${NEANTIK_NOTARY_PROFILE:-}" ]]; then
  declared "NEANTIK_NOTARY_PROFILE is declared; Apple access is verified on submission"
else
  missing "NEANTIK_NOTARY_PROFILE environment value"
fi

echo
if (( MISSING == 0 )); then
  echo "Distribution preflight passed."
  exit 0
fi

echo "Distribution preflight has $MISSING missing requirement(s)." >&2
exit 2
