# NeAntik Chromium runtime

NeAntik is a native macOS profile manager. Browser-visible privacy and
fingerprint behavior is implemented in the bundled Chromium runtime, not by
injecting JavaScript into visited pages.

## Current source contract

The candidate runtime is Chromium `152.0.7977.64`, ARM64-only:

- `runtime/chromium-152-source-contract.json` pins the official Chromium
  source archive, macOS packaging layer, common ungoogled-chromium inputs and
  every NeAntik-owned source input;
- `runtime/chromium-152-rebase-plan.json` records the reviewed rebase;
- `runtime/chromium-152-toolchain-lock.json` pins the build toolchain resources
  that are not fully hashed by the upstream macOS packaging manifest;
- `runtime/nevision-patches/series.json` is the executable owned-patch manifest.

The source contract deliberately says `binaryBindingStatus:
pending-new-build`. Source evidence is not binary evidence. The checked
`runtime/fingerprint-chromium.lock.json` continues to describe the last
verified Chromium `151.0.7922.108` runtime until a new Chromium
`152.0.7977.64` Metal bundle is built, verified and explicitly promoted.

Do not edit the checked runtime lock merely to make version gates green.

## Security and privacy boundaries

The owned Chromium patchset provides deterministic profile separation for
Canvas, WebGL pixels, OfflineAudio and ClientRects, plus a reviewed Apple
Silicon device tuple, real runtime version, locale/timezone context and public
NeAntik branding.

Profile seed and timezone are supplied to Chromium through the child process
environment (`NEANTIK_PROFILE_SEED` and `NEANTIK_PROFILE_TIMEZONE`). They are
not exposed in command-line arguments. The manager builds a minimal allowlist
of required system variables, discards ambient proxy/TLS/token variables and
then sets the validated values for the selected profile.

Proxy passwords stay in macOS Keychain and never enter Chromium arguments.
HTTP/HTTPS authentication uses Chromium's native authentication flow. SOCKS5
username/password authentication is intentionally unsupported until it can be
implemented without putting a secret in process arguments or logs.

For proxied profiles NeAntik disables non-proxied UDP, QUIC, DNS prefetch,
asynchronous DNS and automatic DNS-over-HTTPS, and uses a fail-closed host
resolver policy. Direct profiles use an explicit direct route.

The product goal is privacy and stable profile separation. The patchset must
not include automation-evasion, webdriver hiding, CAPTCHA bypass, ban evasion
or anti-fraud bypass behavior.

## Prepare and verify source

The build wrapper is resumable:

```sh
scripts/build-runtime.sh /absolute/path/to/neantik-chromium-152 prepare
scripts/build-runtime.sh /absolute/path/to/neantik-chromium-152 configure
scripts/build-runtime.sh /absolute/path/to/neantik-chromium-152 build
```

Running without a phase performs the complete sequence. The wrapper:

- refuses non-ARM64 hosts and unverified source inputs;
- verifies the official Chromium archive and pinned Git objects;
- installs build helpers inside the build root;
- applies upstream macOS/common patches and all NeAntik-owned patches exactly
  once;
- verifies exact postimage hashes from the owned manifest;
- emits source provenance and an immutable candidate lock;
- configures an official ARM64 build with Metal and `symbol_level=0`;
- keeps `chrome_pgo_phase=0`, matching the verified public runtime, because
  the pinned official lite archive does not carry the macOS PGO profile and
  the release pipeline never downloads an unpinned optimization input;
- builds only the shipping Chromium app target, with bounded parallelism and a
  persistent log. `chromedriver` is not a product or release dependency.

The default is four Ninja jobs because large Blink translation units can cause
memory-compression churn on 16 GB Apple Silicon Macs. Override it only with an
integer from 1 through 12:

```sh
NEANTIK_NINJA_JOBS=6 \
  scripts/build-runtime.sh /absolute/path/to/neantik-chromium-152 build
```

Xcode installs the Metal compiler as an optional component. The wrapper checks
for it before configuration:

```sh
xcodebuild -downloadComponent MetalToolchain
xcrun --find metallib
```

An explicit `NEANTIK_NO_METAL=1` build is diagnostic only. It can validate
compilation and the launch protocol, but it is never acceptable as a public
release runtime.

Source provenance can be regenerated and compared independently:

```sh
python3 scripts/export-runtime-source-provenance.py \
  /absolute/path/to/neantik-chromium-152/build/src

python3 scripts/verify-runtime-source-provenance.py \
  /absolute/path/to/neantik-chromium-152/build/source-provenance.json \
  --source-root /absolute/path/to/neantik-chromium-152/build/src
```

The generated evidence contains no local absolute source path.

## Verify the owned patchset

All eleven release-required groups in `series.json` are ported to Chromium
`152.0.7977.64`. The manifest is release-ready source evidence, not proof that
a shipping binary exists.

```sh
scripts/verify-nevision-patchset-manifest.py
scripts/verify-nevision-patchset-manifest.py --source-evidence
scripts/verify-nevision-patchset-manifest.py \
  --release \
  --source-evidence \
  --source-root /absolute/path/to/chromium/src
```

The release verifier checks safe paths, patch SHA-256 values, exact Chromium
152 postimages, forbidden scopes and clean patch application evidence. An
`already-applied` result is accepted only when every recorded postimage matches
the source tree; stock preimages cannot masquerade as an applied patch.

## Verify and promote a built runtime

After building, the normal one-command candidate path signs the nested browser
bundle, verifies it, promotes the exact candidate lock and regenerates notices:

```sh
NEANTIK_RELEASE_CHANNEL=public-alpha \
NEANTIK_SIGNING_IDENTITY="Developer ID Application: …" \
scripts/prepare-direct-runtime-candidate.sh \
  "/absolute/path/to/NeAntik Browser.app" \
  /absolute/path/to/out/Default/args.gn \
  /absolute/path/to/chromium/src \
  /absolute/path/to/build/runtime-candidate-lock.json
```

The lower-level verification and promotion commands remain available for
diagnostics:

```sh
scripts/verify-built-runtime.sh \
  "/absolute/path/to/NeAntik Browser.app" \
  /absolute/path/to/runtime-verification.json \
  /absolute/path/to/out/Default/args.gn \
  /absolute/path/to/build/source-provenance.json \
  /absolute/path/to/build/runtime-candidate-lock.json
```

The schema-3 report binds the actual executable/framework hashes, ARM64 Mach-O
inventory, signature, runtime version, Metal build arguments, candidate-lock
hash, source provenance, security baseline, owned patchset and device tuples.
Fresh inspection and packaged evidence must match on immutable fields.

Promotion is intentionally separate:

```sh
scripts/promote-runtime-candidate-lock.py \
  /absolute/path/to/build/runtime-candidate-lock.json \
  /absolute/path/to/build/source-provenance.json \
  "/absolute/path/to/NeAntik Browser.app" \
  /absolute/path/to/out/Default/args.gn \
  /absolute/path/to/runtime-verification.json \
  --confirm-promote-source-lock
```

Promotion reruns binary verification, requires Metal, compares the fresh and
reviewed reports and writes the checked lock atomically. Without the explicit
confirmation flag it writes nothing.

## Behavioral A → B → A evidence

Binary verification does not prove browser behavior. The same production audit
coordinator can be run through the developer CLI:

```sh
scripts/run-runtime-audit.sh \
  "/absolute/path/to/NeAntik Browser.app/Contents/MacOS/NeAntik Browser" \
  /absolute/path/to/fingerprint-audit.json

scripts/verify-gui-fingerprint-report.py \
  /absolute/path/to/fingerprint-audit.json
```

The public-alpha gate requires stable A-repeat values and meaningful A/B
separation across required surfaces. The stricter production gate also checks:

- repeated-call stability;
- page and dedicated-worker CPU/memory coherence;
- OffscreenCanvas and main-canvas coherence;
- CSS screen/DPR media queries;
- WebGL pixels, metadata and shader precision;
- real User-Agent and Client Hints;
- timezone, locale and languages;
- bounded candidate-type-only WebRTC evidence;
- loopback STUN positive control for Direct and zero STUN requests for proxied
  captures.

Raw ICE candidates, IP addresses, proxy credentials, profile names, profile
identifiers and measured site values are not included in the public-safe
summary.

For an engineering-only `headless_shell`, the separate
`--headless-single-process-diagnostic` mode remains available. Its report is
explicitly diagnostic and cannot qualify a GUI release.

## Direct release acceptance

Before publication:

1. prove every source and patch hash;
2. build and verify ARM64-only Metal runtime;
3. verify profile CRUD, data isolation and proxy behavior;
4. pass GUI A → B → A for the exact candidate;
5. sign nested code and the manager with Developer ID;
6. notarize, staple and pass Gatekeeper;
7. package notarized ZIP and DMG;
8. publish the exact version, changelog, runtime version, sizes and SHA-256;
9. download both public artifacts and repeat integrity/Gatekeeper checks.

NeAntik is Direct Distribution only. No App Store or App Store Connect workflow
is part of this project.
