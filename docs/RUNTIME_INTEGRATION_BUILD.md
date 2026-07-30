# NeAntik Chromium integration build

Verified on 25 July 2026.

This is an Apple Silicon integration artifact, not a public production
release. It exists to complete the interactive NeAntik fingerprint gate from
a normal user-launched Terminal/Finder context.

## Proven locally

- Chromium `144.0.7559.132`.
- Official ARM64 build with the normal ANGLE Metal backend enabled.
- Apple Metal shaders compiled by the signed official Metal Toolchain
  `17C7003j`; generated MetalLib verified as a macOS Metal library.
- Pinned fingerprint-chromium and ungoogled-chromium-macos source pair.
- Exact-preimage NeAntik overlay applied to five files.
- 22 implementation-defined hash expressions replaced with
  `base::PersistentHash`.
- Exact-preimage source-branding overlay applied to Chromium branding,
  `Info.plist`, app icon, and core product strings.
- Main executable, Framework, and five Helper processes are source-built as
  `NeAntik Browser…` with the `app.neantik.runtime` identifier family.
- 476 core user-facing Chromium brand strings now say NeAntik while
  `The Chromium Authors` and ChromiumOS technical strings remain intact.
- 13 nested Mach-O files are ARM64-only.
- Deep ad-hoc code signature passes strict verification.
- Fingerprint protocol strings are present in the linked framework.
- `NeAntik Browser --version` reports the exact pinned version.

Historical no-Metal evidence:

- Executable SHA-256:
  `7714781740be69b3e390511b03bdb3cdff97725fc9a8d17510fa5426875a713c`
- Framework SHA-256:
  `f373c1b21a5b50c5f83576da1c5363cf2734fa324727f7a96d974640d2ae1a49`
- `args.gn` SHA-256:
  `bca52f3a2aad107aed969d9c60f849137210708f0ba054839ca8c3e8b618ec97`
- Source lock SHA-256:
  `6df1367982b6cc220849352c43baf51d29371fcb81a2a86202044e8bac1622e1`
- Overlay script SHA-256:
  `a21d74c0a820864478ceadf8518191529e46a113ddb065616f26c99ed640353c`
- Branding overlay script SHA-256:
  `3471c71fc5122e39f8c32841b5a7c405cf131b5d929b50253ec9b07e4c2b46a5`
- NeAntik icon SHA-256:
  `421defe904b8cc761d9cac3ed226e8d864cc7ecb0ab281a76bde5e67b61f317a`
- Source-branded runtime report:
  `artifacts/looper-goals/20260724-fingerprint-runtime/runtime-verification-source-branded-metal.json`

Current Metal runtime evidence:

- Executable SHA-256:
  `d6efeb3b32e4ea23966c53276fd5718bf3d4e4d6746be024eba134a0548b32bc`
- Framework SHA-256:
  `8f29983b22ad46d211081ae1827914abc8e40632a8b0b1cd99210f01ec5dbc1d`
- `args.gn` SHA-256:
  `5f11e1361304f44ffd89c6ae7af893f98a29d764a281ee50d500a37e6ae99383`
- Generated ANGLE MetalLib SHA-256:
  `8899043fee7d460890e7fad25855c8a4f9fa4e1d711f05d98c4659bd622cfdf9`
- Binary gate: 13/13 Mach-O ARM64, strict deep signature, exact Chromium
  version and fingerprint protocol strings.

Base Chromium verification kit:

- `dist/NeAntik-Chromium-144.0.7559.132-arm64-no-metal-integration-kit.zip`
- Size: approximately 138 MB compressed and 346 MB extracted.
- Archive SHA-256:
  `8ac3a1f939793f63bf568df3dc77743d5214e37959ee94c4ec04a8525799bca3`

The archive contains the runtime, the ARM64 audit CLI, a Finder-launchable
audit command, pinned source/build evidence, and the Chromium,
fingerprint-chromium, and ungoogled-chromium-macos licenses. It was extracted
into a fresh directory and passed the same runtime verifier again after the
round trip.

Preferred branded verification kit:

- `dist/NeAntik-144.0.7559.132-arm64-no-metal-branded-integration-kit.zip`
- Size: approximately 140 MB compressed.
- Archive SHA-256:
  `7780ca3caf63190d5611ed70b46882958a9cece0e33443a37ca0ab4048afeb1e`
- Outer app: `NeAntik Browser.app`.
- Bundle identifier: `app.neantik.runtime`.
- Branded executable SHA-256 after ad-hoc signing:
  `8eaa9f823d3d6ad13bcdfb52ea42ca7055562262ed5885912ba13d6edb3409b0`
- NeAntik icon SHA-256:
  `421defe904b8cc761d9cac3ed226e8d864cc7ecb0ab281a76bde5e67b61f317a`

The preferred archive also completed a fresh extraction and repeated the full
runtime verifier without changing its version, framework hash, architecture,
protocol strings, or pinned provenance.

That wrapper-branded kit is retained as historical integration evidence. The
current behavioral gate must use the Metal source-branded kit:

- `dist/NeAntik-144.0.7559.132-source-branded-runtime-audit-kit.zip`
- SHA-256:
  `26306403741f5411a9232d8a52cf9f72d9162e9f44a90eacbc366ef32ec9c122`
- Outer app, executable, Framework, Helpers, identifiers, strings, and icon
  are all produced by the pinned source build.
- The package contains an independently built ARM64 audit CLI and a
  Finder-launchable command.
- ZIP symlinks are preserved; fresh extraction passed the complete Metal
  runtime, signature, ARM64, protocol, provenance, CLI, and launcher gates.
- The archive is built without AppleDouble/Finder metadata, and the round-trip
  verifier reads the packaged `evidence/runtime-verification.json`.

Historical no-Metal all-in-one Direct test package:

- `dist/NeAntik-0.3.5-arm64-no-metal-integrated.zip`
- Size: approximately 160 MB compressed and 385 MB extracted.
- Archive SHA-256:
  `a556764b73b3c38c838ea7c5bf56234d6fb0d6d2ddfb0c9b4611debcc767c72e`
- Manager: NeAntik `0.3.5 (8)`, native ARM64 SwiftUI.
- Bundled runtime: `NeAntik Browser 144.0.7559.132`, ARM64.

The archive was extracted into a fresh directory and
`verify-integrated-release.sh` passed again. The verifier checks the outer
manager signature, the nested runtime gate, exact bundle declarations,
automatic-discovery strings in the optimized manager binary, the pinned lock,
the NeAntik icon, all three root license hashes, 559 Chromium-generated
notices entries, and an SPDX 2.2 document with 579 packages and 573 extracted
licenses.

Current source-branded all-in-one Direct test package:

- `dist/NeAntik-0.3.10-arm64-metal-integrated.zip`
- Archive SHA-256:
  `1304c6ae5f55deeb1e73bdc25551303f24074f7aca4d0f55d897c4095155a34e`
- Manager: NeAntik `0.3.10 (13)`, native ARM64 SwiftUI.
- Bundled runtime: `NeAntik Browser 144.0.7559.132`, ARM64, Metal build.

The archive was extracted into a fresh directory and passed the complete
integrated verifier again. The current binary gate records Metal from the exact
bundled `args.gn`; the actual browser-visible WebGL renderer remains something
the GUI fingerprint report must measure rather than assume.
The ZIP is created without AppleDouble/Finder metadata, because those `._*`
entries invalidate strict code-sign verification after extraction.
The app bundle also includes a classic `Contents/PkgInfo` file so
LaunchServices sees a complete macOS application bundle.

## Run the remaining gate

1. Extract
   `NeAntik-144.0.7559.132-source-branded-runtime-audit-kit.zip` with Finder.
2. Open `Run-NeAntik-Runtime-Audit.command`.
3. Allow Terminal to run it if macOS asks.
4. Wait for the direct WebRTC control and three Chromium launches:
   profile A, profile B, profile A.
5. Keep `fingerprint-audit.json` and `fingerprint-audit-terminal.log` only on
   the owner Mac. They contain private raw evidence and must not be attached
   to issues, uploaded to GitHub or published on the site.
6. After collection, share only `dist/fingerprint-audit-summary.json`. It is
   an aggregate attestation without captures, profile identifiers, identity
   codes or browser-surface values.

The command runs the same `FingerprintAuditCoordinator` and JavaScript probe as
NeAntik Direct. Diagnostic mode can prove protocol behavior with verdict
`verified`, at least two available changed critical surfaces, and no unstable
critical surface. It never qualifies a production release. Production
qualification additionally requires browser mode, every critical surface plus
WebGL vendor/renderer available and stable, and different WebGL pixels between
profiles.

The package also includes `verify-gui-fingerprint-report.py`. The Finder
launcher runs it automatically after the browser audit, and the same verifier is
used only for private diagnostic reports:

```bash
scripts/verify-gui-fingerprint-report.py \
  /absolute/path/to/fingerprint-audit.json \
  --runtime-lock runtime/fingerprint-chromium.lock.json
```

Raw schema-7 reports cannot enter the Direct release matrix. A release uses
the exact prepared manager, schema-3 manifest and an explicit new schema-8
output; the signed manager derives and signs the public-safe aggregate.

The Codex environment cannot perform this GUI gate: Chromium processes inherit
the `com.openai.codex` coalition and abort inside Apple's
`_RegisterApplication`; LaunchServices also returns a false
`kLSNoExecutableErr` for the otherwise verified bundle.

## Still required before public distribution

- production GUI behavioral report, including browser-visible WebGL;
- remaining visual QA for the source-branded browser UI;
- final legal review of licenses, notices, source attribution, and SBOM;
- Developer ID signing, hardened runtime, notarization, and stapling;
- a public update/download channel;
- final regression and user-context GUI QA.

Это историческое доказательство Chromium 144 сохранено только для
воспроизводимости. Текущий продукт имеет единственный Direct release path;
новая публикация должна использовать Chromium 150 source contract и полный
Direct release gate.

## Integration branding

The reproducible integration branding wrapper can create an externally named
`NeAntik Browser.app` without renaming Chromium's internal framework and
helper binaries:

```bash
./scripts/brand-runtime-integration.sh \
  /absolute/path/to/Chromium.app \
  "/absolute/path/to/NeAntik Browser.app"
```

It requires the exact pinned Chromium version, refuses to replace an existing
output, applies the NeAntik icon and outer bundle metadata, ad-hoc signs the
result, and runs strict deep signature verification. This is suitable for the
legacy user-context integration audit only. NeAntik `0.3.8` now uses
source-level branding; public distribution still requires the final Developer
ID signing flow.
