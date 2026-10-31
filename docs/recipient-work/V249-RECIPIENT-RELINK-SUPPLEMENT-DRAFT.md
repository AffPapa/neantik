# Recipient relink supplement — V249 private draft

This draft supplements, but does not modify, the V246 source offer or its signed candidate. It is not a complete corresponding-source offer or proof that a recipient can load a rebuilt engine. The older offer recipe points to `docs/evidence/webkit-v20-recipient-relink-route-20261025.md` in the implementation checkout; that historical file is retained in the release workspace, not in the tracked V246 source archive. Its instructions refer to an older source archive and must not be applied verbatim to V246.

The V246 manager archive already contains the recipient preflight and notice-installer changes; do not apply their historical companion patches again. Use the V246 input manifest and the pinned WebKit source, source patch and V36 build change described by the existing recipe. Preserve the exact required replacement overlays and their notices. The same-Mac V135 clean build is evidence for its pinned inputs only; it does not prove this full recipient procedure.

The following command shapes were checked against `--help` in source commit `adc79f068cbf6974e21bd23e6abfb28ebc857911`. They are a route to exercise, not a verified end-to-end recipe. The recipient must supply a clean WebKit build tree and a separately built, signed disposable manager app with its own Developer ID team, as well as a separately linked production-mode host. The complete manager build recipe, portable dependency closure, source/notice applicability and replacement/load result remain open.

```sh
python3 "$NEANTIK_SOURCE/scripts/stage-webkit-runtime.py" \
  --upstream-source "$WEBKIT_SOURCE" \
  --manifest "$NEANTIK_SOURCE/runtime/webkit-production-staging-v4.json" \
  "$WEBKIT_BUILD" "$NEW_FRAMEWORKS"

python3 "$NEANTIK_SOURCE/scripts/build-webkit-standalone-host.py" \
  --configuration release --production-proxy

python3 "$NEANTIK_SOURCE/scripts/resign-webkit-recipient-runtime.py" \
  --manager-app "$RECIPIENT_MANAGER_APP" \
  --source-frameworks "$NEW_FRAMEWORKS" \
  --output-frameworks "$NEW_SIGNED_FRAMEWORKS" \
  --identity "$RECIPIENT_DEVELOPER_ID"

python3 "$NEANTIK_SOURCE/scripts/package-webkit-host.py" \
  --app "$RECIPIENT_MANAGER_COPY" --host-binary "$BUILT_HOST" \
  --runtime-frameworks "$NEW_SIGNED_FRAMEWORKS" \
  --identity "$RECIPIENT_DEVELOPER_ID" --recipient-relink
```

Use new, distinct output paths and disposable copies. The manager used to authenticate the signing team and the manager copy used for packaging must have a valid signature from that same team. Packaging modifies the manager copy; re-sign and verify it before any launch. The existing distribution pipeline's V122 source/notice guards must not be weakened or used as evidence for different V135 rebuilt bytes. Bind rebuilt image and notice evidence to the actual replacement before a recipient test. The signed production candidate, its existing manifest, and previous source-offer draft remain immutable.

## Manager build boundary

The tracked `Package.swift` defaults `NEANTIK_WEBKIT_PROXY_BUILD_MODE` to `disabled`. The production preparation script sources `scripts/resolve-webkit-proxy-build-mode.sh`, which selects `production` for the production release channel, and then uses SwiftPM's release configuration, native build system and `arm64`. A recipient building the manager outside that script must deliberately select `NEANTIK_WEBKIT_PROXY_BUILD_MODE=production`; running plain `swift build -c release` produces a manager with the proxy feature disabled. This is a source-derived observation, not a verified standalone build recipe.

The existing full production preparation script starts from an already signed source app containing the Chromium runtime and updater/provisioning material, and checks signing continuity and pinned source/build/notice inputs. It is therefore not yet a portable bootstrap from just the offered source archive. A recipient still needs a documented reproducible route for those manager app inputs and must verify its own signed replacement launch. Do not reuse an existing personal app or its credentials for that test.

The tracked `scripts/package-integrated-app.sh` is the upstream construction route for the integrated manager app. It expects four absolute inputs: a built NeAntik Browser.app, its `args.gn`, the matching Chromium source root, and its runtime candidate lock. For the 156.0.8078.48 variant it selects `runtime/chromium-15648-source-contract.json`; it requires source provenance beside the Chromium source and verifies the lock and build path. This command is an identified dependency, not a verified independent-recipient build. The WebKit offer alone cannot supply those four Chromium artifacts, and blindly using the public production packaging path is not an established replacement procedure.

A separate older `scripts/prepare-direct-runtime-candidate.sh` explicitly refuses owned-WebKit host injection; do not use it as the 1.0 owned-WebKit packager. The active production path is `prepare-direct-manager-update.sh` with its owned-host prerequisites. This distinction concerns the existing code paths and does not establish that either produces a portable recipient build.
