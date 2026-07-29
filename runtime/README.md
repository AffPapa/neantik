# NeAntik Chromium runtime

NeAntik Direct is a native profile manager. Browser-visible fingerprint
changes must be implemented inside Chromium, not by page-level JavaScript.

The first reproducible source candidate is pinned in
`fingerprint-chromium.lock.json`:

- `adryfish/fingerprint-chromium` supplies the BSD-3-Clause fingerprint patch
  set and the command-line protocol already used by NeAntik.
- `ungoogled-software/ungoogled-chromium-macos` supplies the BSD-3-Clause macOS
  ARM64 build, signing, and packaging layer.
- the macOS build repository's `ungoogled-chromium` submodule is deliberately
  replaced with the pinned fingerprint fork, as the fingerprint project
  documents.

This pin is a source-integration checkpoint, not a claim that NeAntik owns a
tested production browser binary. The two upstream tags share Chromium major
144 but not the same patch release. Patch application, compilation, runtime
behavior, signing, and the A -> B -> A fingerprint audit must all pass before a
binary can be called a NeAntik runtime.

## Prepare the exact source pair

```sh
scripts/prepare-runtime-source.sh /absolute/path/to/nevision-chromium-build
```

The destination must be absent or empty. The script clones only the two pinned
repositories and verifies their Git objects and critical file hashes. It does
not download Chromium source or start the very large compilation.

To re-check an existing prepared tree:

```sh
scripts/verify-runtime-source.sh /absolute/path/to/nevision-chromium-build
```

## Reproducible Apple Silicon build

After preparing the pinned source pair, run:

```sh
scripts/build-runtime.sh /absolute/path/to/nevision-chromium-build
```

The wrapper:

- refuses non-ARM64 hosts and unverified source pairs;
- installs pinned Python/Ninja helpers inside the build directory rather than
  modifying the user's global Python installation;
- supplies a portable `greadlink -f` implementation for a clean macOS host;
- downloads and verifies the exact Chromium, LLVM, Node, and Rust resources;
- applies binary pruning, all fingerprint/macOS patches, and domain
  substitution exactly once;
- verifies the unpacked `chrome/VERSION` against the locked Chromium runtime
  version before accepting a fresh or resumed source stamp;
- applies an exact-preimage NeAntik overlay that replaces the fingerprint
  fork's implementation-defined `std::hash` calls with Chromium's specified
  `base::PersistentHash`;
- applies a separate exact-preimage source-branding overlay for the NeAntik
  product name, bundle identifiers, executable/Framework/Helper names,
  runtime metadata, app icon, and core browser strings;
- uses resumable phase stamps;
- generates an ARM64 official-build configuration with `symbol_level=0`;
- builds `chrome` and `chromedriver` with bounded parallelism;
- keeps a persistent build log under `build/nevision-runtime-arm64.log`.

The current macOS dependency manifest publishes SHA-512 for LLVM and Node but
omits a digest for its Rust nightly archive. NeAntik therefore pins the
official Rust URL, size and SHA-256 in
`runtime/chromium-150-toolchain-lock.json`; the build refuses to execute that
compiler when the archive does not match.

Chromium documents `base::PersistentHash` as permanently frozen: the same
message retains the same value across Chromium revisions. It is used here for
repeatable profile-derived noise, not as a cryptographic primitive.

Xcode 26 installs its Metal compiler as an optional Apple component. Install it
once before the configure/build phase:

```sh
xcodebuild -downloadComponent MetalToolchain
xcrun --find metallib
```

The wrapper checks this up front so a clean build does not discover the missing
component thousands of compile steps later. Apple documents both the Xcode
Components UI and this command-line installation method:
<https://developer.apple.com/documentation/Xcode/downloading-and-installing-additional-xcode-components>.

For an explicitly non-production fingerprint integration build, ANGLE Metal
can be disabled while retaining Chromium's compiled OpenGL and SwiftShader
fallbacks:

```sh
NEANTIK_NO_METAL=1 \
  scripts/build-runtime.sh /absolute/path/to/nevision-chromium-build build
```

This mode exists only to validate compilation, the launch protocol, profile
isolation, and deterministic A -> B -> A behavior on a machine where the
optional Metal compiler cannot yet be installed. It does not promise which
fallback Chromium will select at runtime; the A -> B -> A report must retain
the actual WebGL vendor, renderer, and pixels. It is not an acceptable shipping
GPU fingerprint, and production acceptance still requires the normal Metal
build and its full behavioral audit.

## Chromium 150 owned patchset handoff

The public-release rebase uses `runtime/nevision-patches/series.json` as the
owned NeAntik patchset handoff. It is currently a verified port plan, not a
ported patch series.

```sh
scripts/verify-nevision-patchset-manifest.py
scripts/verify-nevision-patchset-manifest.py --source-evidence
scripts/verify-nevision-patchset-manifest.py --release --source-evidence
scripts/verify-nevision-patchset-manifest.py --release --source-evidence --source-root /absolute/chromium/src
```

The release form intentionally fails until every group has a real patch file
with `patchSHA256`, safe-relative Chromium 150 postimage paths, a clean
`git apply --check --whitespace=nowarn`, and locked Chromium 150 postimage
hashes.

The manifest top-level `status` is also executable release evidence. It must be
`planned-not-ported` when every group is still planned, `partially-ported` when
some but not all groups are ported, and `release-ready` only when no planned
release-required groups remain. The verifier rejects mismatched status strings
before the workbench or release gate can use the manifest.

Individual phases can be resumed explicitly:

```sh
scripts/build-runtime.sh /absolute/path/to/nevision-chromium-build prepare
scripts/build-runtime.sh /absolute/path/to/nevision-chromium-build configure
scripts/build-runtime.sh /absolute/path/to/nevision-chromium-build build
```

Set `NEANTIK_NINJA_JOBS` to an integer from 1 through 12 to tune build
parallelism. The default is 4: Chromium's large Blink translation units caused
severe memory-compression churn with 6 concurrent jobs on a 16 GB Apple
Silicon Mac. Higher values remain available for machines with more memory.

## Verify the built bundle

After the build and local or Developer ID signing, run:

```sh
scripts/verify-built-runtime.sh \
  "/absolute/path/to/NeAntik Browser.app" \
  /absolute/path/to/runtime-verification.json \
  /absolute/path/to/out/Default/args.gn
```

This gate verifies the exact pinned Chromium version, ARM64-only architecture
for all nested Mach-O code, the deep code signature, runtime `--version`
output, fingerprint protocol strings in the linked framework, and SHA-256
evidence for the main executable and framework. When `args.gn` is supplied, its
SHA-256 and the proven `metal` or `no-metal` build mode are retained in
the report. Without it, the verifier deliberately records the mode as
`unrecorded`. The report also distinguishes local ad-hoc signing from a
Developer ID identity. This does not replace the behavioral A -> B -> A audit.
Runtime verification report schema 2 includes the source-lock, upstream
fingerprint and macOS packaging patch-series hashes, the owned NeAntik patch
manifest, reviewed Apple device-tuple catalog, security baseline, both
deterministic overlays, build arguments, and executable/framework SHA-256
values. Packaged and freshly inspected reports must match on every immutable
field.

To run that behavioral gate without depending on UI automation, use the same
production audit coordinator and probe through the small developer CLI:

```sh
scripts/run-runtime-audit.sh \
  "/absolute/path/to/NeAntik Browser.app/Contents/MacOS/NeAntik Browser" \
  /absolute/path/to/fingerprint-audit.json
```

It launches fixed profile A, profile B, and profile A again with fresh
disposable data directories, writes the normal NeAntik JSON report, and exits
nonzero unless the verdict is `verified`. The CLI is compiled into a temporary
build directory and is not included in either NeAntik app bundle.

To qualify that JSON as public-release GUI evidence, run the independent gate:

```sh
scripts/verify-gui-fingerprint-report.py \
  /absolute/path/to/fingerprint-audit.json
```

This emits separate `publicAlphaQualified` and `productionQualified` verdicts.
The public-alpha gate rejects diagnostic mode, missing binary hashes,
unavailable required browser surfaces, unstable A-repeat values, invalid
A -> B -> A profile identity, and device-tuple mismatches. The strict
production gate additionally requires fingerprint audit schema 5 evidence for
repeat-call stability including OfflineAudio, main-realm / Web Worker and
OffscreenCanvas coherence, CSS
screen/DPR media-query coherence, WebGL shader precision, and bounded
candidate-type-only WebRTC route evidence plus a same-run loopback STUN direct
positive control and zero STUN requests for proxied captures. Raw ICE candidate strings,
addresses, hostnames, and derived hashes are not persisted. The current
signed GUI release still has to produce fresh `loopback-stun-v1` evidence
before the shipped binary can be qualified. A legacy schema 1
report may remain valid alpha evidence but cannot be promoted to strict
production evidence.

For a source-built bare `headless_shell` inside a restricted engineering
environment, use the separately marked diagnostic mode:

```sh
scripts/run-runtime-audit.sh \
  /absolute/path/to/headless_shell \
  /absolute/path/to/fingerprint-audit.json \
  --headless-single-process-diagnostic
```

The report records this mode and the CLI warns that it is not production GUI
release evidence. The normal browser path never receives the diagnostic
`--single-process --no-sandbox` arguments.

## Build spike acceptance gate

Run the upstream macOS build only on an isolated Apple Silicon builder with
enough disposable disk and time for a full Chromium build. Before distribution:

1. prove every patch applies without fuzz or rejects;
2. build only `target_cpu = "arm64"`;
3. run the NeAntik A -> B -> A audit and retain its JSON report;
4. test Canvas, WebGL pixels and metadata, Audio, ClientRects, UA/Client Hints,
   fonts, screen/device values, timezone, locale, and WebRTC in both the main
   realm and a Web Worker where the API exists;
5. prove repeated reads, OffscreenCanvas results, CSS media queries, and WebGL
   shader precision are deterministic and coherent;
6. reject unstable per-load noise and internally inconsistent combinations;
7. rebrand bundle identifiers and visible Chromium branding;
8. preserve Chromium and all third-party notices;
9. sign nested code with NeAntik's Developer ID, notarize, staple, and verify;
10. publish the exact lock, source attribution, binary SHA-256, and SBOM beside
   the release.

The Direct app must keep accepting a separately installed runtime until this
gate is complete. The Mac App Store edition remains WebKit-only.
