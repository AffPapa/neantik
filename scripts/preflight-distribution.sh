#!/bin/zsh

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STORE_PROFILE_VERIFIER="$SCRIPT_DIR/verify-store-profile.py"
STORE_METADATA_VERIFIER="$SCRIPT_DIR/verify-app-store-metadata.py"
MODE="${1:-all}"
if [[ "$MODE" != "all" && "$MODE" != "direct" && "$MODE" != "store" ]]; then
  echo "Usage: $0 [all|direct|store]" >&2
  exit 64
fi

IDENTITIES="$(security find-identity -v -p codesigning 2>&1)"
# Installer identities are intentionally not returned by the codesigning
# policy filter. productbuild still needs their exact certificate common name.
INSTALLER_IDENTITIES="$(security find-identity -v 2>&1)"
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

identity_prefix_is_installed() {
  local prefix="$1"
  printf '%s\n' "$IDENTITIES" | grep -Fq "\"$prefix"
}

identity_line_for() {
  local identity="$1"
  local identity_line
  if [[ "$identity" =~ '^[0-9A-Fa-f]{40}$' ]]; then
    identity_line="$(
      printf '%s\n' "$IDENTITIES" |
        grep -Ei "[[:space:]]${identity}[[:space:]]" |
        head -n 1
    )"
  else
    identity_line="$(
      printf '%s\n' "$IDENTITIES" |
        grep -F "\"$identity\"" |
        head -n 1
    )"
  fi
  printf '%s\n' "$identity_line"
}

identity_matches_prefix() {
  local identity="$1"
  local prefix="$2"
  local identity_line
  identity_line="$(identity_line_for "$identity")"
  [[ "$identity_line" == *"\"$prefix"* ]]
}

identity_common_name() {
  local identity_line
  identity_line="$(identity_line_for "$1")"
  printf '%s\n' "$identity_line" |
    sed -E 's/.*"([^"]+)".*/\1/'
}

installer_identity_prefix_is_installed() {
  local prefix="$1"
  printf '%s\n' "$INSTALLER_IDENTITIES" | grep -Fq "\"$prefix"
}

installer_identity_line_for() {
  local identity="$1"
  printf '%s\n' "$INSTALLER_IDENTITIES" |
    grep -F "\"$identity\"" |
    head -n 1
}

installer_identity_has_valid_prefix() {
  local identity_line
  identity_line="$(installer_identity_line_for "$1")"
  [[ "$identity_line" == *'"Mac Installer Distribution:'* ||
     "$identity_line" == *'"3rd Party Mac Developer Installer:'* ]]
}

preflight_direct() {
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
}

preflight_store() {
  echo "Mac App Store distribution"
  local selected_identity_name=""
  local metadata_output=""

  if metadata_output="$(
    PYTHONDONTWRITEBYTECODE=1 \
      python3 "$STORE_METADATA_VERIFIER" --submission 2>&1
  )"; then
    pass "App Store metadata, privacy answers, contacts, and screenshots are complete"
  else
    missing "complete App Store submission metadata"
    printf '%s\n' "$metadata_output" |
      sed 's/^/        /' >&2
  fi

  if identity_prefix_is_installed "Apple Distribution:"; then
    pass "Apple Distribution identity is installed"
  else
    missing "Apple Distribution identity"
  fi

  if [[ -n "${NEANTIK_STORE_SIGNING_IDENTITY:-}" ]]; then
    if identity_matches_prefix \
      "$NEANTIK_STORE_SIGNING_IDENTITY" \
      "Apple Distribution:"; then
      pass "NEANTIK_STORE_SIGNING_IDENTITY resolves to Apple Distribution"
      selected_identity_name="$(
        identity_common_name "$NEANTIK_STORE_SIGNING_IDENTITY"
      )"
    else
      missing "NEANTIK_STORE_SIGNING_IDENTITY does not resolve to Apple Distribution"
    fi
  else
    missing "NEANTIK_STORE_SIGNING_IDENTITY environment value"
  fi

  if installer_identity_prefix_is_installed "Mac Installer Distribution:" ||
     installer_identity_prefix_is_installed \
       "3rd Party Mac Developer Installer:"; then
    pass "Mac App Store installer identity is installed"
  else
    missing "Mac App Store installer identity"
  fi

  if [[ -n "${NEANTIK_STORE_INSTALLER_IDENTITY:-}" ]]; then
    if [[ "$NEANTIK_STORE_INSTALLER_IDENTITY" =~ '^[0-9A-Fa-f]{40}$' ]]; then
      missing "NEANTIK_STORE_INSTALLER_IDENTITY must use the certificate name, not SHA-1"
    elif installer_identity_has_valid_prefix \
      "$NEANTIK_STORE_INSTALLER_IDENTITY"; then
      pass "NEANTIK_STORE_INSTALLER_IDENTITY resolves to a Mac App Store installer identity"
    else
      missing "NEANTIK_STORE_INSTALLER_IDENTITY does not resolve to a Mac App Store installer identity"
    fi
  else
    missing "NEANTIK_STORE_INSTALLER_IDENTITY environment value"
  fi

  local profile="${NEANTIK_STORE_PROVISIONING_PROFILE:-}"
  if [[ -z "$profile" ]]; then
    missing "NEANTIK_STORE_PROVISIONING_PROFILE environment value"
    return
  fi
  if [[ "$profile" != /* || ! -f "$profile" ]]; then
    missing "absolute existing Mac App Store provisioning profile"
    return
  fi

  local profile_plist
  local certificate_pem
  profile_plist="$(mktemp -t nevision-distribution-profile)"
  certificate_pem="$(mktemp -t nevision-distribution-certificate)"
  if ! security cms -D -i "$profile" >"$profile_plist" 2>/dev/null; then
    rm -f "$profile_plist" "$certificate_pem"
    missing "decodable Mac App Store provisioning profile"
    return
  fi

  if [[ -z "$selected_identity_name" ]]; then
    rm -f "$profile_plist" "$certificate_pem"
    missing "profile/certificate match cannot be verified without selected Apple Distribution identity"
    return
  fi

  if ! security find-certificate \
      -c "$selected_identity_name" \
      -p >"$certificate_pem" 2>/dev/null ||
     [[ ! -s "$certificate_pem" ]]; then
    rm -f "$profile_plist" "$certificate_pem"
    missing "selected Apple Distribution certificate export"
    return
  fi

  local verification_output
  if verification_output="$(
    python3 "$STORE_PROFILE_VERIFIER" \
      --plist "$profile_plist" \
      --bundle-id app.neantik.store \
      --certificate-pem "$certificate_pem" 2>&1
  )"; then
    pass "unexpired Mac App Store profile matches selected certificate"
    printf '%s\n' "$verification_output" |
      sed 's/^/        /'
  else
    missing "valid matching Mac App Store provisioning profile"
    printf '%s\n' "$verification_output" |
      sed 's/^/        /' >&2
  fi
  rm -f "$profile_plist" "$certificate_pem"
}

case "$MODE" in
  direct)
    preflight_direct
    ;;
  store)
    preflight_store
    ;;
  all)
    preflight_direct
    echo
    preflight_store
    ;;
esac

echo
if (( MISSING == 0 )); then
  echo "Distribution preflight passed."
  exit 0
fi

echo "Distribution preflight has $MISSING missing requirement(s)." >&2
exit 2
