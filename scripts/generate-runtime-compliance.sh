#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() {
  echo "Usage: $0 /absolute/path/to/chromium/src /absolute/output/directory /absolute/path/to/runtime-candidate-lock.json" >&2
}

if [[ $# -ne 3 ]]; then
  usage
  exit 64
fi

SOURCE_ROOT="$1"
OUTPUT_DIR="$2"
LOCK_FILE="$3"

if [[ "$SOURCE_ROOT" != /* || ! -d "$SOURCE_ROOT" ]]; then
  echo "Chromium source root must be an existing absolute path." >&2
  exit 66
fi
if [[ "$OUTPUT_DIR" != /* ]]; then
  echo "Output directory must be absolute." >&2
  exit 64
fi
if [[ "$LOCK_FILE" != /* || ! -f "$LOCK_FILE" || -L "$LOCK_FILE" ]]; then
  echo "Candidate lock must be an absolute regular non-symlinked file." >&2
  exit 66
fi

VERSION="$(
  plutil -extract fingerprintChromium.chromiumVersion raw -o - "$LOCK_FILE"
)"
LICENSE_TOOL="$SOURCE_ROOT/tools/licenses/licenses.py"
CREDITS_SOURCE="$SOURCE_ROOT/out/Default/gen/components/resources/about_credits.html"

if [[ ! -f "$LICENSE_TOOL" || ! -f "$CREDITS_SOURCE" ]]; then
  echo "Chromium license generator or built credits artifact is missing." >&2
  exit 66
fi

mkdir -p "$OUTPUT_DIR"
CREDITS_OUTPUT="$OUTPUT_DIR/THIRD-PARTY-NOTICES.html"
SPDX_OUTPUT="$OUTPUT_DIR/NeAntik-Chromium-$VERSION.spdx.json"
MANIFEST_OUTPUT="$OUTPUT_DIR/compliance-manifest.json"

cp "$CREDITS_SOURCE" "$CREDITS_OUTPUT"

SOURCE_LOCK_SHA256="$(
  shasum -a 256 "$LOCK_FILE" | awk '{print $1}'
)"
DOCUMENT_NAMESPACE="https://neantik.app/spdx/chromium-$VERSION-$SOURCE_LOCK_SHA256"
SOURCE_LINK="https://chromium.googlesource.com/chromium/src/+/refs/tags/$VERSION"

python3 "$LICENSE_TOOL" license_file \
  --scan-root "$SOURCE_ROOT" \
  --target-os mac \
  --format spdx \
  --spdx-root "$SOURCE_ROOT" \
  --spdx-link "$SOURCE_LINK" \
  --spdx-doc-name "NeAntik Chromium $VERSION" \
  --spdx-doc-namespace "$DOCUMENT_NAMESPACE" \
  "$SPDX_OUTPUT"

chmod 644 "$CREDITS_OUTPUT" "$SPDX_OUTPUT"

PROJECT_DIR="$PROJECT_DIR" \
VERSION="$VERSION" \
SOURCE_LOCK_SHA256="$SOURCE_LOCK_SHA256" \
LICENSE_TOOL="$LICENSE_TOOL" \
CREDITS_OUTPUT="$CREDITS_OUTPUT" \
SPDX_OUTPUT="$SPDX_OUTPUT" \
MANIFEST_OUTPUT="$MANIFEST_OUTPUT" \
python3 - <<'PY'
import hashlib
import json
import os
from pathlib import Path

def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

credits_path = Path(os.environ["CREDITS_OUTPUT"])
spdx_path = Path(os.environ["SPDX_OUTPUT"])
tool_path = Path(os.environ["LICENSE_TOOL"])
spdx = json.loads(spdx_path.read_text(encoding="utf-8"))
credits_text = credits_path.read_text(encoding="utf-8")

manifest = {
    "schemaVersion": 1,
    "chromiumVersion": os.environ["VERSION"],
    "sourceLockSHA256": os.environ["SOURCE_LOCK_SHA256"],
    "generator": {
        "path": "tools/licenses/licenses.py",
        "sha256": sha256(tool_path),
    },
    "notices": {
        "file": credits_path.name,
        "sha256": sha256(credits_path),
        "entryCount": credits_text.count('<div class="product">'),
    },
    "spdx": {
        "file": spdx_path.name,
        "sha256": sha256(spdx_path),
        "spdxVersion": spdx.get("spdxVersion"),
        "documentNamespace": spdx.get("documentNamespace"),
        "packageCount": len(spdx.get("packages", [])),
        "extractedLicenseCount": len(
            spdx.get("hasExtractedLicensingInfos", [])
        ),
    },
}
Path(os.environ["MANIFEST_OUTPUT"]).write_text(
    json.dumps(manifest, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY

chmod 644 "$MANIFEST_OUTPUT"
"$SCRIPT_DIR/verify-runtime-compliance.sh" "$OUTPUT_DIR" "$LOCK_FILE"

echo "NeAntik runtime compliance artifacts generated."
echo "Version:  $VERSION"
echo "Output:   $OUTPUT_DIR"
