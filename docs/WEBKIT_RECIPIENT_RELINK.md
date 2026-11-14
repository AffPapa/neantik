# Relink NeAntik with a locally built WebKit

This procedure replaces the owned WebKit in a separate application copy. It
uses the 627.1.8 build recipe and the corresponding source and notices from
the exact NeAntik release. Run the commands from the matching NeAntik source
checkout, using Python 3.11 or later. Use a separate macOS account or VM to
open the resulting copy. Its production bundle ID uses that account's normal
NeAntik application support and Keychain.

Build and stage WebKit using the source offer recipe. Apply your changes to
the source before building and keep the generated `stage.json`. The steps
below support code changes that keep the supplied runtime resources, broker
sandbox and 16 Mach-O paths. Set the following variables to absolute paths
and to the independently verified manifest digest from the release.

```bash
export PYTHONDONTWRITEBYTECODE=1
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
shipped=/path/to/extracted/NeAntik.app
frameworks=/path/to/recipient/build/frameworks-with-notices
stage=/path/to/recipient/build/stage.json
offer=/path/to/extracted/source-offer
offer_pin=SHA256_FROM_RELEASE
identity=RECIPIENT_DEVELOPER_ID_APPLICATION_SHA1
team=RECIPIENT_TEAM_ID
```

Verify the publisher's ZIP against its published digest before extracting
the application. Then verify that the application and selected certificate
are usable. Make an owner-only work directory and copy the application there.
Preserve the original signed bundle as the rollback copy.

```bash
set -euo pipefail
codesign --verify --deep --strict "$shipped"
work=$(mktemp -d /private/tmp/neantik-recipient.XXXXXXXX)
copy="$work/NeAntik.app"
ditto "$shipped" "$copy"
host="$copy/Contents/Helpers/webkit-v1/NeAntikWebKitHost.app"
cp -p "$host/Contents/MacOS/NeAntikWebKitHost" "$work/NeAntikWebKitHost"
mv "$host" "$work/original-WebKit-host.app"
```

For a different Developer ID team, record that team and disable the
publisher's update and backup features in the copy. Remove the publisher's
provisioning profile from the copy before shallow signing. This procedure
qualifies replacement of owned WebKit. Chromium's authenticated proxy requires
Chromium and its helpers to be signed by the manager's team.

```bash
python3 -B - "$copy" "$team" <<'PY'
import plistlib
import re
import sys
from pathlib import Path

app = Path(sys.argv[1])
team = sys.argv[2]
if not re.fullmatch(r"[A-Z0-9]{10}", team):
    raise SystemExit("Expected a Developer ID team identifier")
contents = app / "Contents"
file = contents / "Info.plist"
info = plistlib.loads(file.read_bytes())
if info.get("CFBundleIdentifier") != "app.neantik.desktop":
    raise SystemExit("Expected the production manager")
info["NeAntikDeveloperTeamIdentifier"] = team
for key in ("NeAntikUpdateChannelEnabled", "NeAntikUpdateAutoDownload",
            "NeAntikUpdateOwnerContinuityRequired", "NeAntikBrowserDataBackupEnabled"):
    info[key] = False
(contents / "embedded.provisionprofile").unlink(missing_ok=True)
file.write_bytes(plistlib.dumps(info))
PY
codesign --force --options runtime --timestamp --sign "$identity" "$copy"
codesign --verify --deep --strict "$copy"
```

Sign the recipient's Frameworks tree, verify the correspondence of all images
and install the new host. The publisher notice manifest stays pinned. The
packager checks the separate recipient stage and writes a local relink receipt.

```bash
stage_pin=$(shasum -a 256 "$stage" | cut -d ' ' -f 1)
sandbox_pin=$(plutil -extract networkSandbox.patchedSHA256 raw -o - "$stage")
signed="$work/Frameworks-signed"
python3 -B scripts/resign-webkit-recipient-runtime.py \
  --manager-app "$copy" --source-frameworks "$frameworks" \
  --output-frameworks "$signed" --identity "$identity"
python3 -B scripts/verify-recipient-runtime-lineage.py \
  --source-frameworks "$frameworks" --signed-frameworks "$signed" \
  --binding "$signed.NeAntikRuntimeImageBinding.json" --team "$team"
python3 -B scripts/package-webkit-host.py --recipient-relink --app "$copy" \
  --host-binary "$work/NeAntikWebKitHost" --runtime-frameworks "$signed" \
  --identity "$identity" --network-sandbox-sha256 "$sandbox_pin" \
  --source-offer-root "$offer" --source-offer-manifest-sha256 "$offer_pin" \
  --recipient-stage "$stage" --recipient-stage-sha256 "$stage_pin"
codesign --force --options runtime --timestamp --sign "$identity" "$copy"
codesign --verify --deep --strict "$copy"
python3 -B scripts/verify-webkit-host-pin.py "$copy" --require-network-sandbox-pin
python3 -B scripts/webkit_runtime_notices.py --verify --app "$copy" \
  --runtime-frameworks "$host/Contents/Frameworks" --source-offer-root "$offer" \
  --source-offer-manifest-sha256 "$offer_pin" --recipient-stage "$stage" \
  --recipient-stage-sha256 "$stage_pin"
```

Keep the source changes, `stage.json` and the signed image binding together.
The application copy records which images changed in
`Contents/Resources/NeAntikRuntimeEvidence/LocalWebKitRelink.json`.
To observe the replacement at runtime, use a synthetic isolated WebKit profile
in the separate account or VM and check the loaded image against the signed
host's pins after opening a test page. The local relink checks do not confer
the publisher's notarization ticket on the copy.
