# WebKit v20 build and relink recipe — draft

Status: **partial, not a complete corresponding-source or recipient build offer**. This recipe records the retained v20 production build and a successful clean relocated configure/build/relink on the same Mac. It does not establish an external-recipient build, binary-identical reproduction, license compliance, or publication authorization.

## Pinned inputs

- WebKit commit: `43d5b8d85e2e5eed41d7ff8a79da831bf405be6c`
- WebKit source archive SHA-256: `658ca48ecfdaa341991bc9cd773a0aa394dabe90ccd1851021433fbd9e72df9f`
- NeAntik WebKit patch SHA-256: `b33b9320bd8f3bae56eadebc738fe91d40f0cf77e89fd2885bf28679d2af0735`
- NeAntik recipient preflight companion patch SHA-256: `b8141e001cde0d0ff573eb87a850dbda5ef2a9f9059eef8414cf219758b1c2ff` (`patches/recipient-preflight-v20.patch`). Apply only to the extracted `NeAntik-source-955bc08.tar.zst` tree. An isolated `git apply --check`/apply replay produced the exact improved script SHA-256 `5c87a0dc91efb2b2ef5f58e2e259ece7428536ad2479d233e7b4e12fa4cc0f84`; the source archive is unchanged.
- Notice installer and package-test source overlay SHA-256: `f92113ed129644b6032dd72b6e0f393b38a65aa4615f491782524bec0027b0cd` at `patches/notice-installer-overlay-20261025.patch`. It includes the exact `scripts/webkit_runtime_notices.py`, its focused tests, and the package-host test updated for the pinned v20 WebRTC notice set. Apply this manager-source overlay to a fresh extracted NeAntik tree before running the WebKit notice installer/package tests; it does not change the pinned WebKit archive, WebKit patch, or prior relink inputs. The exact official MPL-1.1, GPL-2.0 and provenance manifest files are under `docs/evidence/third-party/official-license-texts-20261025/`. This adds scoped JSDateMath.cpp alternative notice support; it does not select one license option or close other JSC image obligations.
- The exact notice-installer inputs missing from the frozen manager archive are in `notice-source-inputs-v20.tar` (85 files; SHA-256 `826a1a04a536e5cdc332bea9d1738c95af38727500ecca96e58d203fc16a8bf7`), indexed by `evidence/NOTICE_SOURCE_INPUTS_MANIFEST_V20.json`. Extract this overlay into the extracted NeAntik source root before notice checks. Replaying the manager archive, installer/test patch, input bundle, and official license texts passed all 86 notice-installer and package-host tests; see `evidence/WEBKIT_JSDateMath_trilicense_notice_integration_V20.json`. This is source/package workflow evidence, not runtime or license-election evidence.
- Observed configure settings: see `BUILD-CONFIG-v20.json` (146 feature options; CMakeCache SHA-256 `bf38a4db6cf695dbc6b88d878c379521a97b87d7ea93c1ef493c0f9b929ea17c`).

The pinned manager archive already contains the runtime staging and recipient re-sign/package tools, `runtime/webkit-production-staging-v4.json`, and the pinned CompatibilitySpan input. Its archived preflight has obsolete implicit v16 defaults, so use the explicit v20 input manifest after applying the companion patch. That preflight's exit status covers known inputs only; it does not establish complete source dependencies or recipient replacement. The audited sequence and remaining conditions are recorded in `docs/evidence/webkit-v20-recipient-relink-route-20261025.md` in the implementation checkout.

## Observed toolchain

Xcode 27.0 build 27A5228h, macOS SDK 27.0, CMake 4.4.3, Ninja 1.13.2, arm64, deployment target 15.4, Python 3.15.0, Ruby 2.6.10, Perl 5.34.1. These are observations from the retained build, not a promise that other versions reproduce identical output.

## Captured configure command

Set these paths to the extracted source tree, an empty output directory, and the included patch. The recorded configure command ran with the build directory as its working directory.

```sh
export NEANTIK_WEBKIT_SOURCE_ROOT="/path/to/extracted/WebKit"
export NEANTIK_WEBKIT_BUILD_ROOT="/path/to/new-build-output"
export NEANTIK_WEBKIT_PATCH="/path/to/webkit-v20-source-modifications.patch"

cd "$NEANTIK_WEBKIT_SOURCE_ROOT"
git apply --check "$NEANTIK_WEBKIT_PATCH"
git apply "$NEANTIK_WEBKIT_PATCH"
mkdir -p "$NEANTIK_WEBKIT_BUILD_ROOT"
cd "$NEANTIK_WEBKIT_BUILD_ROOT"

xcrun --sdk macosx27.0 cmake -DPORT="Cocoa" -DCMAKE_OSX_SYSROOT="macosx27.0" -DCMAKE_BUILD_TYPE=Release -G Ninja -DCMAKE_MAKE_PROGRAM="$NEANTIK_WEBKIT_SOURCE_ROOT/Source/cmake/ninja-wrapper" -DSHOW_BINDINGS_GENERATION_PROGRESS=1 -DDEVELOPER_MODE=ON -DENABLE_GPU_PROCESS=ON -DENABLE_WEBXR=OFF -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=15.4 -DUSE_SYSTEM_MALLOC=OFF -DENABLE_WRITING_TOOLS=OFF -DCMAKE_Swift_FLAGS="-module-cache-path $NEANTIK_WEBKIT_BUILD_ROOT/SwiftModuleCache" "$NEANTIK_WEBKIT_SOURCE_ROOT"
```

This is the captured v20 configuration with its original absolute roots replaced by these variables. The original command and configure-log hash are preserved in `evidence/WEBKIT_CONFIGURE_EVIDENCE_V20.json`. This command does not by itself prove every external transitive dependency is included or that another machine can reproduce the configuration.

## Clean relocated relink result

The matching Ninja graph resolved all 14 output paths. A clean extraction of the pinned archive, checked/applied patch, fresh CMake configure, and all 14 requested Ninja targets completed successfully on the same Mac using two workers. Receipt: `evidence/WEBKIT_CLEAN_RELOCATED_RELINK_V20.json`. This demonstrates the documented recipe in a clean relocated tree on this machine; it is not an outside-recipient result or bit-for-bit reproduction. The clean cache differed only in the developer-tooling option `CLANGD_AUTO_SETUP` (ON in the original tree, OFF by default in the clean configure) plus normalized relocated path fields. Xcode 27.0/SDK 27.0, Swift 6.4, arm64 and deployment target 15.4 matched.

```sh
ninja -C "$NEANTIK_WEBKIT_BUILD_ROOT" -j2 JavaScriptCore.framework/Versions/A/JavaScriptCore WebGPU.framework/Versions/A/WebGPU libANGLE-shared.dylib libwebrtc.dylib WebCore.framework/Versions/A/WebCore WebKitLegacy.framework/Versions/A/WebKitLegacy WebInspectorUI.framework/Versions/A/WebInspectorUI WebKit.framework/Versions/A/WebKit WebKit.framework/Versions/A/XPCServices/app.neantik.desktop.webkit.GPU.xpc/Contents/MacOS/app.neantik.desktop.webkit.GPU.Development WebKit.framework/Versions/A/XPCServices/app.neantik.desktop.webkit.WebContent.xpc/Contents/MacOS/app.neantik.desktop.webkit.WebContent.Development WebKit.framework/Versions/A/XPCServices/app.neantik.desktop.webkit.Networking.xpc/Contents/MacOS/app.neantik.desktop.webkit.Networking.Development WebKit.framework/Versions/A/XPCServices/app.neantik.desktop.webkit.WebContent.CaptivePortal.xpc/Contents/MacOS/app.neantik.desktop.webkit.WebContent.CaptivePortal.Development WebKit.framework/Versions/A/XPCServices/app.neantik.desktop.webkit.WebContent.EnhancedSecurity.xpc/Contents/MacOS/app.neantik.desktop.webkit.WebContent.EnhancedSecurity.Development libWebKitSwift.dylib
```

## Link outputs

The exact v20 build log records 14 requested link outputs; each output path resolves uniquely in the matching Ninja graph. See `evidence/WEBKIT_OUTPUT_TARGET_INVENTORY_V20.json` for the full path, Ninja rule, and build-log line map; `evidence/WEBKIT_CONFIGURE_EVIDENCE_V20.json` binds the normalized configure invocation and log hash. The retained final action was `[1311/1311] Linking Swift shared library libWebKitSwift.dylib`. Do not treat this as an external recipient reproduction or candidate qualification.

### Exact configured link/source closure (2026-10-25)

The retained matching `build.ninja` graph was queried without compiling. It contains 14 runtime output nodes plus 7 internal static-library nodes. Separating Ninja edge types gives 3,157 explicit object link inputs and 573 implicit object dependencies; the latter are not counted as linked objects. Those explicit objects map to 3,040 unique compiler primary inputs with no missing source edges. The node-by-node object-to-source map includes the internal static archive relationships.

The matching retained Ninja dependency log provides 22,849 unique, SHA-256-bound transitive dependency paths for 3,052 explicit objects. The remaining 105 explicit Swift objects have no ordinary Ninja depfile records. Their exact declared source/module graph is captured separately: 5 Swift-module nodes, 4,934 input rows, and 106 unique hashed file paths (4,730 pinned source-tree rows and 204 generated build-tree rows), with zero missing file inputs. Six CMake order-only nodes are phony scheduling edges, not missing files. This graph does not prove every Swift compiler implicit import or Xcode tool input. Xcode SDK/toolchain dependencies remain machine-provided inputs.

### Exact compile-source license evidence candidates

A source-header pass over the exact 3,040 compiler primary inputs found 2,790 pinned-source files and 250 generated build-tree inputs. It records 673 leading-header license markers and nearest ancestor candidate license-text paths for 2,773 source inputs (40 unique candidate text paths overall), joined per runtime image by the exact linker-source map. The full path/hash/marker/candidate index is `evidence/WEBKIT_LINK_SOURCE_LICENSE_CANDIDATES_V20.json`.

For 12 additional unmarked generated WebCore implementation outputs, the exact Ninja lineage resolves 36 unique physical generator inputs, all hash-matched to the retained v20 source/build tree. A separate source-header candidate preserves 29 explicit leading copyright/license signals and records seven inputs without such a signal. It is staged at `notices/webcore/WebCore-GENERATED-INPUT-HEADERS.txt`; its row/output map is `evidence/WEBKIT_WEBCORE_GENERATED_INPUT_HEADERS_V20.json`. The next-package notice installer copies and verifies this text. Output license applicability and the four image-row decisions remain open.

For 124 linked generated libwebrtc assembly outputs, the exact output hashes and all 62 unique BoringSSL Perl generator input hashes match the retained v20 tree. Every generator has an explicit Apache-2.0 source header. Their header text is staged at `notices/webrtc/GeneratedInputHeaders.txt` with the output/input map at `evidence/WEBKIT_WEBRTC_GENERATED_INPUT_HEADERS_V20.json`; the next-package notice installer copies and verifies the text. The existing WebRTC candidate notice bundle includes the pinned BoringSSL `src/LICENSE`, WebRTC `PATENTS`, and other component texts. Whether all linked component and patent duties are covered remains under review; this does not resolve the libwebrtc image row.

This scan is an evidence index only. A nearest ancestor license file or header marker is not by itself a legal applicability decision. The current package worksheet has 82 UNKNOWN decisions (4 runtime images and 78 resources). Twelve image rows and six sandbox-template resource rows have bounded factual maintainer reviews; none constitutes legal approval. The remaining image/resource rows must be reviewed against exact source and required notices.

### Runtime-resource source and license candidates

The exact candidate worksheet maps all 84 packaged resources to upstream source paths. A separate hash pass confirms 62 single-file rows are byte-identical to their mapped source; 22 have a transformation or multi-source boundary that remains documented per row. The index records nearest candidate license filenames and any textual header signals. Six sandbox-template rows retain their existing factual match; 78 resource applicability decisions remain UNKNOWN. See `evidence/WEBKIT_RUNTIME_RESOURCE_LICENSE_CANDIDATES_V20.json`.

Resource/source equality and a nearby license filename are factual provenance, not a decision that the text applies or which package notice is required.



Receipts:

- `evidence/WEBKIT_PRODUCTION_LINK_INPUT_CLOSURE_V20.json`
- `evidence/WEBKIT_PRODUCTION_LINK_DEPENDENCY_CLOSURE_V20.json`
- `evidence/WEBKIT_RUNTIME_IMAGE_SOURCE_CLOSURE_V20.json`
- `evidence/WEBKIT_RUNTIME_IMAGE_LICENSE_EVIDENCE_JOIN_V20.json`
- `evidence/WEBKIT_SWIFT_LINK_INPUT_CLOSURE_V20.json`

The candidate package has 16 runtime-image rows. Exact configured link/source mapping covers 15 rows (14 exact path matches and one unique basename match); `libswiftCompatibilitySpan.dylib` has no configured Ninja link node. A join to the earlier source/license crosswalk matches 67 source rows to six candidate license texts across 10 image rows; 3,037 source rows do not match that earlier crosswalk by exact path and hash. These are evidence leads only, not decisions about applicable licenses or required notices.


## Still required before this offer is complete

1. Enumerate and include/provide the complete transitive source/dependency set needed by a recipient, including generated inputs and applicable third-party source/notices.
2. **Completed on this Mac only:** clean relocated configure, build, and relink from the pinned source archive and patch, without relying on the original absolute paths. An independent external recipient has not run the procedure.
3. Resolve the current 82 UNKNOWN runtime notice applicability decisions: 4 image rows and 78 resource rows. Six sandbox resource rows and twelve image rows have bounded factual reviews; do not treat those reviews as resolving the remaining rows or as legal approval. Use exact source/license evidence and place required notices in the package/source offer.
4. Reuse the completed internal engineering proof; do not repeat the clean relink or headed image load. The v20 patch replay, fresh-source compile/link, exact loaded-image evidence, marker-free rebuild, and this clean relocated relink are separately receipted. These results do not qualify production candidate 139 or close source/dependency and license obligations.

Until these items are closed, this is useful build evidence but not the complete source/relink offer required by the 1.0 plan.
