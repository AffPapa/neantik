# Recipient production build and WebKit replacement recipe — V265 draft

Status: V265 corrects a packaging omission found while rechecking V264: the raw Chromium build must first be branded with the exact runtime candidate lock. This source-derived recipe has not been exercised by an independent recipient, is not part of the frozen V246 source offer, and does not prove a signed replacement load. Do not modify the b960 candidate or its bound source offer to add this file.

This is a two-input runtime workflow: the recipient supplies/builds the matching Chromium runtime and a signed integrated manager source app; the recipient separately builds owned WebKit and the standalone production host from the pinned WebKit source offer. The maintained scripts assemble and sign those inputs. The source offer must contain or point to immutable, hash-verified Chromium source/build inputs and the required WebKit inputs; a WebKit-only archive is insufficient.

## 1. Build and brand the Chromium runtime, then package the integrated base app

Required Chromium inputs, all from the same version/build: a built raw `Chromium.app`, its exact `args.gn`, matching Chromium `src` tree, `runtime-candidate-lock.json` emitted beside source provenance, and `source-provenance.json`. For the current 156.0.8078.48 contract, the project expects `runtime/chromium-15648-source-contract.json` and its pinned patch/evidence files. The source/build/lock relationship is checked during packaging; do not substitute a public runtime or a lock from another build. Branding must use that same candidate lock because the legacy project-wide lock still pins 156.0.8078.12.

Create the NeAntik-branded runtime from the raw Chromium build output:

```sh
scripts/brand-runtime-integration.sh \
  "$CHROMIUM_APP" "$NEANTIK_BROWSER_APP" "$CHROMIUM_RUNTIME_CANDIDATE_LOCK"
```

This copies the raw app, applies outer bundle metadata and icon, then ad-hoc signs and verifies the branded bundle. This ad-hoc signature is an intermediate packaging input, not the Developer ID release signature. The three-argument form checks the runtime version against the exact candidate lock; the two-argument legacy form still reads the project-wide legacy lock.

```sh
NEANTIK_RELEASE_CHANNEL=production \
NEANTIK_SIGNING_IDENTITY='<recipient Developer ID Application identity>' \
NEANTIK_DIRECT_PROVISIONING_PROFILE='<recipient profile path when required>' \
  scripts/package-integrated-app.sh \
    "$NEANTIK_BROWSER_APP" "$CHROMIUM_ARGS_GN" "$CHROMIUM_SOURCE_ROOT" "$CHROMIUM_RUNTIME_CANDIDATE_LOCK"
```

This entrypoint packages an already-built and branded Chromium runtime; it does not build Chromium from source. It invokes the manager packaging path with the owned WebKit host disabled to create the signed integrated source app. A portable offer must separately give recipients the exact Chromium source revision, patches, build configuration, dependency/toolchain acquisition, and provenance-generation route. The required built runtime and provenance files cannot be inferred from `args.gn` alone.

## 2. Build the owned WebKit runtime and production host

Use the exact WebKit source commit/archive and patch pair bound by the offer. Before building `WebKit_Assets`, apply the source-offer-bound first-party warning-color catalog replacements to the clean extracted source tree, then run the single asset target. The source offer binds all nine catalog source files and the resulting `Assets.car` SHA-256; do not substitute an existing catalog from another build:

```sh
python3 tools/apply_neantik_resource_overlay.py \
  --source-tree "$WEBKIT_SOURCE_ROOT" \
  --overlay-root "$WEBKIT_SOURCE_OFFER_ROOT/overlays/neantik-first-party-warning-colors-v1"
ninja -C "$WEBKIT_BUILD_ROOT" -j2 WebKit_Assets
```

Then generate the complete staged Frameworks set and compile the host in production mode:

```sh
python3 scripts/stage-webkit-runtime.py \
  --upstream-source "$WEBKIT_SOURCE_ROOT" \
  --manifest "$NEANTIK_SOURCE/runtime/webkit-production-staging-v4.json" \
  "$WEBKIT_BUILD_ROOT" "$STAGED_FRAMEWORKS"

python3 scripts/build-webkit-standalone-host.py \
  --configuration release --production-proxy
```

The actual release package step must verify the exact build receipt, source-offer manifest, image set, notice inputs and signing identity. The maintained `package-owned-webkit-release.py` applies the 55 source-offer-pinned static runtime overlays to its disposable Frameworks staging tree, verifies the compiled `Assets.car` receipt, and prepares resources before signing; do not manually patch a retained candidate. The static overlays are package inputs and are not applied by `stage-webkit-runtime.py` alone. Do not use `--diagnostic-proxy` or `--qa-proxy` for production. Keep the generated host and framework tree tied to the same source/build receipt.

## 3. Assemble and sign the production manager candidate

The manager production script builds the manager from source using SwiftPM release/arm64, native build system and jobs2; `resolve-webkit-proxy-build-mode.sh` exports `NEANTIK_WEBKIT_PROXY_BUILD_MODE=production` when `NEANTIK_RELEASE_CHANNEL=production`. Plain `swift build -c release` defaults the proxy mode to disabled and is not an equivalent production build.

Provide the already signed integrated source app from step 1, plus the following exact WebKit inputs:

- `NEANTIK_WEBKIT_BUILD_ROOT`: physical pinned WebKit build root.
- `NEANTIK_WEBKIT_SOURCE_ROOT`: physical clean source root matching that build.
- `NEANTIK_WEBKIT_BUILD_RECEIPT`: receipt for those exact outputs.
- `NEANTIK_WEBKIT_SOURCE_OFFER_ROOT` and `NEANTIK_WEBKIT_SOURCE_OFFER_MANIFEST_SHA256`: frozen corresponding-source offer and its exact manifest digest.
- `NEANTIK_SOURCE_PROVENANCE` and `NEANTIK_RUNTIME_CANDIDATE_LOCK`: the exact Chromium provenance and lock used by the integrated app.
- `NEANTIK_SIGNING_IDENTITY`: the recipient's own Developer ID identity; never distribute the maintainer's private key.
- `NEANTIK_RELEASE_CHANNEL=production` and `NEANTIK_WEBKIT_HOST_ENABLED=1`.

```sh
NEANTIK_RELEASE_CHANNEL=production \
NEANTIK_WEBKIT_HOST_ENABLED=1 \
NEANTIK_SIGNING_IDENTITY='<recipient Developer ID Application identity>' \
NEANTIK_DIRECT_PROVISIONING_PROFILE='<recipient profile path when required>' \
NEANTIK_SOURCE_PROVENANCE="$CHROMIUM_SOURCE_PROVENANCE" \
NEANTIK_RUNTIME_CANDIDATE_LOCK="$CHROMIUM_RUNTIME_CANDIDATE_LOCK" \
NEANTIK_WEBKIT_BUILD_ROOT="$WEBKIT_BUILD_ROOT" \
NEANTIK_WEBKIT_SOURCE_ROOT="$WEBKIT_SOURCE_ROOT" \
NEANTIK_WEBKIT_BUILD_RECEIPT="$WEBKIT_BUILD_RECEIPT" \
NEANTIK_WEBKIT_SOURCE_OFFER_ROOT="$WEBKIT_SOURCE_OFFER_ROOT" \
NEANTIK_WEBKIT_SOURCE_OFFER_MANIFEST_SHA256="$WEBKIT_SOURCE_OFFER_MANIFEST_SHA256" \
  scripts/prepare-direct-manager-update.sh "$SIGNED_INTEGRATED_SOURCE_APP"
```

The manager script validates the signed source app and runtime evidence, builds and packages the manager, applies the owned WebKit host/runtime using the pinned offer, then signs and verifies the output. Keep the required Developer ID secure timestamp; any signing failure is a failed package attempt. The recipient must provide any provisioning profile required by the app's actual entitlement contract through `NEANTIK_DIRECT_PROVISIONING_PROFILE`; do not copy the maintainer's profile or credentials.

`prepare-direct-runtime-candidate.sh` is not an alternative: it refuses owned-WebKit host/framework injection. `prepare-direct-manager-update.sh` is the active path.

## Remaining evidence before this can enter the offer

1. Validate every Chromium and WebKit path, patch, source revision, lock and build receipt against the exact current inputs; the source offer must make large upstream archives retrievable and verifiable.
2. Bind this recipe and its dependencies into a new immutable source-offer manifest; keep V246/b960's manifest frozen.
3. Run the recipient check-only preflight against that exact manifest and confirm all runtime/source notices are present in the assembled candidate.
4. Have a recipient build from the offer, sign with their own identity, replace the owned images, verify the host pin, and load the modified runtime. A same-Mac clean relink or packaging verifier is not this result.
