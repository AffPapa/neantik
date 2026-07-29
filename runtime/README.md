# NeAntik Chromium runtime

NeAntik Direct is a native profile manager. Browser-visible fingerprint
changes must be implemented inside Chromium, not by page-level JavaScript.

The Chromium 150 source inputs for the next build are pinned in
`chromium-150-source-contract.json` and cross-checked against
`chromium-150-rebase-plan.json`. The contract records
`binaryBindingStatus: pending-new-build`: it does not retroactively claim that
the published 0.3.12 binary is bound to those source commits.

- `ungoogled-software/ungoogled-chromium-macos` supplies the BSD-3-Clause macOS
  ARM64 build and packaging layer at commit `9cbd94c...`;
- its recorded Chromium `.181` submodule is deliberately replaced by the
  pinned common `ungoogled-chromium` `150.0.7871.186-1` commit `fd0378e...`;
- the reviewed NeAntik fingerprint changes come from the owned patch manifest
  in `nevision-patches/series.json`.

`fingerprint-chromium.lock.json` still contains legacy Chromium 144 packaging
metadata used by the already-published artifact. It must not be edited to
pretend that artifact has new provenance. Release gates remain blocked until a
new Metal build records the emitted source-provenance SHA-256 in a schema 3
runtime report and the new-candidate lock is regenerated honestly as schema 4.
That lock must bind this source contract, remove legacy fingerprint-fork
integration fields, and repeat the exact mac/common Git objects and critical
file hashes from the contract.

## Verify and export the exact Chromium 150 source evidence

```sh
python3 scripts/export-runtime-source-provenance.py \
  /absolute/path/to/nevision-chromium-150/build/src
python3 scripts/verify-runtime-source-provenance.py \
  /absolute/path/to/nevision-chromium-150/build/source-provenance.json \
  --source-root /absolute/path/to/nevision-chromium-150/build/src
```

The exporter verifies both Git heads and trees, critical Git-object hashes,
the official Chromium source archive and `chrome/VERSION`, the owned patchset,
and the generated Apple tuple layer. It writes atomically and records no local
absolute path. Legacy `prepare-runtime-source.sh` and
`verify-runtime-source.sh` are intentionally blocked for Chromium 150 because
their old layout reads the stale Chromium 144 lock.

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
  /absolute/path/to/out/Default/args.gn \
  /absolute/path/to/build/source-provenance.json \
  /absolute/path/to/build/runtime-candidate-lock.json
```

The owned Chromium 150 configure phase emits both source provenance and a
deterministic schema 4 candidate lock inside the build root. The candidate lock
is timeless and source-only: it contains no timestamps, local paths, binary
hashes, report path, or build/result claim. The schema 3 runtime report is the
one-way binary binding and records the candidate-lock SHA-256. The checked
`runtime/fingerprint-chromium.lock.json` is never overwritten by configure,
build, verification, or packaging.

Promotion is a separate manual operation after review of a fresh Metal report:

```sh
scripts/promote-runtime-candidate-lock.py \
  /absolute/path/to/build/runtime-candidate-lock.json \
  /absolute/path/to/build/source-provenance.json \
  "/absolute/path/to/NeAntik Browser.app" \
  /absolute/path/to/out/Default/args.gn \
  /absolute/path/to/runtime-verification.json \
  --confirm-promote-source-lock
```

Without the explicit confirmation flag the command exits without writing. It
reruns binary verification, requires `angle_enable_metal=true`, compares the
fresh and reviewed reports, then promotes the candidate bytes atomically.

This gate verifies the exact pinned Chromium version, ARM64-only architecture
for all nested Mach-O code, the deep code signature, runtime `--version`
output, fingerprint protocol strings in the linked framework, and SHA-256
evidence for the main executable and framework. When `args.gn` is supplied, its
SHA-256 and the proven `metal` or `no-metal` build mode are retained in
the report. Without it, the verifier deliberately records the mode as
`unrecorded`. The report also distinguishes local ad-hoc signing from a
Developer ID identity. This does not replace the behavioral A -> B -> A audit.
Runtime verification report schema 3 includes the candidate-lock, source
provenance, upstream
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
unavailable required alpha browser surfaces, unstable A-repeat values and an
invalid A -> B -> A profile identity. The strict production gate additionally
requires device-tuple agreement and fingerprint audit schema 7 evidence for
repeat-call stability including OfflineAudio, main-realm / Web Worker
coherence for CPU and device memory, OffscreenCanvas coherence, CSS
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

Новый встроенный Direct runtime нельзя публиковать, пока этот gate не
завершён. Поддержка отдельно выбранного runtime остаётся только явным
инженерным режимом и не подменяет проверку публичного bundle.
