# Chromium 156.0.8078.48 source and build route — V266 draft

Status: reproducible recipient route draft. Its pins are checked against the active release worktree and the existing full Chromium source checkout. It is not yet integrated into a new complete source offer, does not prove an independent recipient build, and does not change b960 or frozen V246.

## Exact source inputs

- Official Chromium repository: `https://chromium.googlesource.com/chromium/src.git`
- Source commit: `d0c02bfad08ec92a6ffcf989e53cd995e6381a4c`
- Source tree: `7f8057b292482977d1eb92dfab20d3b129af4134`
- Version: `156.0.8078.48`, arm64.
- DEPS lock: 150 pinned Git checkouts, including the separately reviewed DevTools and V8 compatibility patches.
- NeAntik, DevTools and V8 patches, Chromium license, source contract, rebase plan, DEPS lock, GN args and source verifier must travel together. Verify their hashes using `runtime/chromium-15648-source-adoption-v3.json` and `runtime/chromium-15648-source-contract.json`.

The recipient must use an empty, disposable checkout path. Install Chromium `depot_tools` following the official [Mac build guide](https://chromium.googlesource.com/chromium/src/%2B/main/docs/mac_build_instructions.md), pin the external `depot_tools` checkout to `a07c06fe67a1a9d64ac4728df3a11c1ceb0cf73e` from `runtime/chromium-15648-deps-lock.json`, and disable its self-update (`DEPOT_TOOLS_UPDATE=0`). Then fetch and sync the exact Chromium commit and its DEPS dependencies:

```sh
mkdir -p "$CHROMIUM_CHECKOUT_ROOT"
cd "$CHROMIUM_CHECKOUT_ROOT"
fetch --no-history chromium
cd src
git checkout --detach d0c02bfad08ec92a6ffcf989e53cd995e6381a4c
gclient sync --revision src@d0c02bfad08ec92a6ffcf989e53cd995e6381a4c
```

Chromium's official [old-revision guidance](https://chromium.googlesource.com/chromium/src.git/%2B/master/docs/building_old_revisions.md) recommends a contemporaneous `depot_tools` revision and disabling auto-update; depot_tools documents `gclient sync --revision src@GIT_COMMIT_OR_REF`. Run this only in the fresh checkout because sync resets source and dependency checkouts.

Apply the three pinned patches from the offer after the clean sync:

```sh
git apply "$OFFER_ROOT/runtime/chromium-15648-neantik-v3.patch"
git -C third_party/devtools-frontend/src apply \
  "$OFFER_ROOT/runtime/chromium-15648-devtools-typescript6.patch"
git -C v8 apply \
  "$OFFER_ROOT/runtime/chromium-15648-v8-scope-iterator-compat.patch"
```

The source verifier now checks all 150 dependency checkout commit/tree pairs and the exact `.gclient_entries` digest before it checks the main source commit/tree, patch replay, DevTools/V8 pins and version. Verify source before generating provenance:

```sh
python3 -B "$OFFER_ROOT/scripts/verify-chromium-15648-source-adoption.py" "$CHROMIUM_CHECKOUT_ROOT/src"
```

## Generate source-only provenance and candidate lock

Set `CHROMIUM_BUILD_ROOT` to the directory containing `src` (the parent of `CHROMIUM_CHECKOUT_ROOT/src`). The packager expects both files beside `src`; these documents bind source/config only and do not claim a built or qualified binary:

```sh
python3 -B "$OFFER_ROOT/scripts/export-runtime-source-provenance.py" \
  "$CHROMIUM_CHECKOUT_ROOT/src" --project-root "$OFFER_ROOT" \
  --output "$CHROMIUM_BUILD_ROOT/source-provenance.json"
python3 -B "$OFFER_ROOT/scripts/export-runtime-candidate-lock.py" \
  "$CHROMIUM_BUILD_ROOT/source-provenance.json" --project-root "$OFFER_ROOT" \
  --output "$CHROMIUM_BUILD_ROOT/runtime-candidate-lock.json"
python3 -B "$OFFER_ROOT/scripts/verify-runtime-source-provenance.py" \
  "$CHROMIUM_BUILD_ROOT/source-provenance.json" \
  --source-root "$CHROMIUM_CHECKOUT_ROOT/src" \
  --runtime-lock "$CHROMIUM_BUILD_ROOT/runtime-candidate-lock.json" \
  --project-root "$OFFER_ROOT"
```

The active source verifier requires the exact GN argument file at `src/out/NeAntikStable156_48/args.gn`. Generate and build the browser using the pinned arguments:

```sh
mkdir -p "$CHROMIUM_CHECKOUT_ROOT/src/out/NeAntikStable156_48"
cp "$OFFER_ROOT/runtime/chromium-15648-args.gn" \
  "$CHROMIUM_CHECKOUT_ROOT/src/out/NeAntikStable156_48/args.gn"
cd "$CHROMIUM_CHECKOUT_ROOT/src"
gn gen out/NeAntikStable156_48 --args="$(cat out/NeAntikStable156_48/args.gn)"
autoninja -C out/NeAntikStable156_48 chrome
```

Official Mac instructions identify the output as `out/Default/Chromium.app`; this recipe uses the equivalent pinned output directory `out/NeAntikStable156_48/Chromium.app`. Verify the generated provenance and candidate lock against the built source, then run the normal exact runtime-report verifier against the app before packaging. Brand with `scripts/brand-runtime-integration.sh` and the same `runtime-candidate-lock.json`, then pass that branded app, exact `args.gn`, source root and lock to `scripts/package-integrated-app.sh`.

## Scope and remaining gates

The current Mac has a source checkout that passes the pinned source/DEPS verifier. A source-only provenance and candidate lock were regenerated under the active release worktree's current contract and verified against that checkout. Their binary binding remains pending until a new build and runtime report are produced. This proves local source inputs only; it does not replace an independent recipient build, owned-WebKit source/notices/relink closure, recipient signed replacement load, production proxy QA, timestamped Developer ID package, notarization or public release.
