#!/bin/zsh

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

usage() {
  echo "Usage: $0 /absolute/path/to/NeAntik\\ Browser.app /absolute/path/to/args.gn /absolute/path/to/runtime-candidate-lock.json" >&2
}

if [[ $# -ne 3 ]]; then
  usage
  exit 64
fi

RUNTIME_APP="$1"
BUILD_ARGS="$2"
CANDIDATE_LOCK="$3"
SOURCE_ROOT="$(
  cd "$(dirname "$BUILD_ARGS")/../.." 2>/dev/null && pwd -P || true
)"
SOURCE_PROVENANCE="$(dirname "$SOURCE_ROOT")/source-provenance.json"
EXPECTED_CANDIDATE_LOCK="$(dirname "$SOURCE_ROOT")/runtime-candidate-lock.json"

if [[ "$RUNTIME_APP" != /* || ! -d "$RUNTIME_APP" ]]; then
  echo "NeAntik Browser.app must be an existing absolute path." >&2
  exit 66
fi
if [[ "$BUILD_ARGS" != /* || ! -f "$BUILD_ARGS" ]]; then
  echo "args.gn must be an existing absolute path." >&2
  exit 66
fi
if [[ "$CANDIDATE_LOCK" != /* ||
      ! -f "$CANDIDATE_LOCK" ||
      -L "$CANDIDATE_LOCK" ]]; then
  echo "Runtime audit kit requires an explicit schema 4 candidate lock." >&2
  exit 66
fi
if [[ "$(cd "$(dirname "$CANDIDATE_LOCK")" && pwd -P)/$(basename "$CANDIDATE_LOCK")" !=
      "$(cd "$(dirname "$EXPECTED_CANDIDATE_LOCK")" && pwd -P)/$(basename "$EXPECTED_CANDIDATE_LOCK")" ]]; then
  echo "Runtime audit candidate lock does not belong to args.gn build root." >&2
  exit 65
fi
if [[ -z "$SOURCE_ROOT" ||
      ! -f "$SOURCE_ROOT/chrome/VERSION" ||
      ! -f "$SOURCE_PROVENANCE" ||
      -L "$SOURCE_PROVENANCE" ]]; then
  echo "Runtime audit kit requires generated Chromium source provenance." >&2
  exit 66
fi
"$PROJECT_DIR/scripts/verify-runtime-candidate-lock.py" \
  "$CANDIDATE_LOCK" \
  "$SOURCE_PROVENANCE"

RUNTIME_PLIST="$RUNTIME_APP/Contents/Info.plist"
RUNTIME_VERSION="$(
  plutil -extract CFBundleShortVersionString raw -o - "$RUNTIME_PLIST"
)"
RUNTIME_EXECUTABLE="$(
  plutil -extract CFBundleExecutable raw -o - "$RUNTIME_PLIST"
)"
RUNTIME_BUNDLE_ID="$(
  plutil -extract CFBundleIdentifier raw -o - "$RUNTIME_PLIST"
)"
RUNTIME_FLAVOR="$(
  plutil -extract NeAntikRuntimeFlavor raw -o - "$RUNTIME_PLIST"
)"
RUNTIME_BUILD_MODE="$(
  plutil -extract NeAntikRuntimeBuildMode raw -o - "$RUNTIME_PLIST"
)"

if [[ "$RUNTIME_EXECUTABLE" != "NeAntik Browser" ||
      "$RUNTIME_BUNDLE_ID" != "app.neantik.runtime" ||
      "$RUNTIME_FLAVOR" != "fingerprint-chromium" ||
      "$RUNTIME_BUILD_MODE" != "source-build" ]]; then
  echo "Runtime is not the source-branded NeAntik fingerprint runtime." >&2
  exit 65
fi

PACKAGE_NAME="NeAntik-${RUNTIME_VERSION}-source-branded-runtime-audit-kit"
OUTPUT_ARCHIVE="$PROJECT_DIR/dist/${PACKAGE_NAME}.zip"
STAGING_ROOT="$(mktemp -d -t nevision-runtime-audit-kit)"
ROUNDTRIP_ROOT="$(mktemp -d -t nevision-runtime-audit-roundtrip)"
VERIFY_REPORT="$(mktemp -t nevision-runtime-audit-verification)"
trap 'rm -rf "$STAGING_ROOT" "$ROUNDTRIP_ROOT"; rm -f "$VERIFY_REPORT"' EXIT

PACKAGE_DIR="$STAGING_ROOT/$PACKAGE_NAME"
EVIDENCE_DIR="$PACKAGE_DIR/evidence"
LICENSES_DIR="$PACKAGE_DIR/licenses"
mkdir -p "$PACKAGE_DIR" "$EVIDENCE_DIR" "$LICENSES_DIR"

"$PROJECT_DIR/scripts/verify-built-runtime.sh" \
  "$RUNTIME_APP" \
  "$VERIFY_REPORT" \
  "$BUILD_ARGS" \
  "$SOURCE_PROVENANCE" \
  "$CANDIDATE_LOCK"

ditto "$RUNTIME_APP" "$PACKAGE_DIR/NeAntik Browser.app"
"$PROJECT_DIR/scripts/build-runtime-audit-cli.sh" \
  "$PACKAGE_DIR/NeAntikRuntimeAudit" >/dev/null
rm -rf "$PACKAGE_DIR/module-cache"

cp "$PROJECT_DIR/scripts/Run-NeAntik-Runtime-Audit.command" "$PACKAGE_DIR/"
chmod 0755 "$PACKAGE_DIR/Run-NeAntik-Runtime-Audit.command"
cp "$PROJECT_DIR/scripts/verify-gui-fingerprint-report.py" "$PACKAGE_DIR/"
chmod 0755 "$PACKAGE_DIR/verify-gui-fingerprint-report.py"
cp "$PROJECT_DIR/docs/RUNTIME_AUDIT_KIT_README.md" "$PACKAGE_DIR/README.md"
cp "$CANDIDATE_LOCK" \
  "$EVIDENCE_DIR/fingerprint-chromium.lock.json"
cp "$PROJECT_DIR/runtime/security-baseline.json" \
  "$EVIDENCE_DIR/security-baseline.json"
cp "$PROJECT_DIR/runtime/nevision-patches/series.json" \
  "$EVIDENCE_DIR/neantik-patch-series.json"
cp "$PROJECT_DIR/runtime/apple-device-tuples.json" \
  "$EVIDENCE_DIR/apple-device-tuples.json"
cp "$PROJECT_DIR/runtime/chromium-152-source-contract.json" \
  "$EVIDENCE_DIR/chromium-152-source-contract.json"
cp "$SOURCE_PROVENANCE" "$EVIDENCE_DIR/source-provenance.json"
cp "$BUILD_ARGS" "$EVIDENCE_DIR/args.gn"
cp "$VERIFY_REPORT" "$EVIDENCE_DIR/runtime-verification.json"
cp "$PROJECT_DIR/runtime/licenses/Chromium-LICENSE" "$LICENSES_DIR/"
cp "$PROJECT_DIR/runtime/licenses/fingerprint-chromium-LICENSE" "$LICENSES_DIR/"
cp "$PROJECT_DIR/runtime/licenses/ungoogled-chromium-macos-LICENSE" "$LICENSES_DIR/"

codesign --verify --deep --strict --verbose=2 \
  "$PACKAGE_DIR/NeAntik Browser.app"
codesign --verify --strict --verbose=2 \
  "$PACKAGE_DIR/NeAntikRuntimeAudit"
bash -n "$PACKAGE_DIR/Run-NeAntik-Runtime-Audit.command"
python3 -m py_compile "$PACKAGE_DIR/verify-gui-fingerprint-report.py"
python3 "$PACKAGE_DIR/verify-gui-fingerprint-report.py" --help >/dev/null
find "$PACKAGE_DIR" -name __pycache__ -type d -prune -exec rm -rf {} +
grep -Fq 'umask 077' "$PACKAGE_DIR/Run-NeAntik-Runtime-Audit.command"
grep -Fq 'fingerprint-audit-terminal.log' \
  "$PACKAGE_DIR/Run-NeAntik-Runtime-Audit.command"
grep -Fq -- '--runtime-lock "$RUNTIME_LOCK"' \
  "$PACKAGE_DIR/Run-NeAntik-Runtime-Audit.command"
grep -Fq 'production-qualified A -> B -> A report' \
  "$PACKAGE_DIR/Run-NeAntik-Runtime-Audit.command"
grep -Fq 'Independent production GUI report verification' \
  "$PACKAGE_DIR/Run-NeAntik-Runtime-Audit.command"

rm -f "$OUTPUT_ARCHIVE"
(
  cd "$STAGING_ROOT"
  COPYFILE_DISABLE=1 zip -X -q -y -r "$OUTPUT_ARCHIVE" "$PACKAGE_NAME"
)

unzip -q "$OUTPUT_ARCHIVE" -d "$ROUNDTRIP_ROOT"
ROUNDTRIP_PACKAGE="$ROUNDTRIP_ROOT/$PACKAGE_NAME"
"$PROJECT_DIR/scripts/verify-built-runtime.sh" \
  "$ROUNDTRIP_PACKAGE/NeAntik Browser.app" \
  "$ROUNDTRIP_PACKAGE/evidence/runtime-verification.json" \
  "$ROUNDTRIP_PACKAGE/evidence/args.gn" \
  "$ROUNDTRIP_PACKAGE/evidence/source-provenance.json" \
  "$ROUNDTRIP_PACKAGE/evidence/fingerprint-chromium.lock.json"
codesign --verify --strict --verbose=2 \
  "$ROUNDTRIP_PACKAGE/NeAntikRuntimeAudit"
bash -n "$ROUNDTRIP_PACKAGE/Run-NeAntik-Runtime-Audit.command"
python3 -m py_compile "$ROUNDTRIP_PACKAGE/verify-gui-fingerprint-report.py"
python3 "$ROUNDTRIP_PACKAGE/verify-gui-fingerprint-report.py" --help >/dev/null
grep -Fq 'fingerprint-audit-terminal.log' \
  "$ROUNDTRIP_PACKAGE/Run-NeAntik-Runtime-Audit.command"
grep -Fq -- '--runtime-lock "$RUNTIME_LOCK"' \
  "$ROUNDTRIP_PACKAGE/Run-NeAntik-Runtime-Audit.command"
grep -Fq 'production-qualified A -> B -> A report' \
  "$ROUNDTRIP_PACKAGE/Run-NeAntik-Runtime-Audit.command"
grep -Fq 'Independent production GUI report verification' \
  "$ROUNDTRIP_PACKAGE/Run-NeAntik-Runtime-Audit.command"

if unzip -Z1 "$OUTPUT_ARCHIVE" |
  grep -Eq '(^|/)__MACOSX/|(^|/)\.DS_Store$|(^|/)\._[^/]+$'; then
  echo "Archive contains forbidden Finder metadata." >&2
  exit 65
fi

ARCHIVE_SHA256="$(shasum -a 256 "$OUTPUT_ARCHIVE" | awk '{print $1}')"
echo "$OUTPUT_ARCHIVE"
echo "SHA-256: $ARCHIVE_SHA256"
