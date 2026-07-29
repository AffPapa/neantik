# NeAntik Chromium runtime notices

This file is generated from the checked-in source contract, runtime lock, owned
patch manifest, and license files. Run:

```bash
python3 scripts/generate-runtime-integration-notices.py --check
```

Do not edit generated values by hand.

## Runtime contract

- Product: `NeAntik Browser`
- Chromium: `150.0.7871.186`
- Architecture: `arm64`
- Historical published runtime lock status: `chromium-150-owned-patchset-metal-runtime-built-gui-audit-pending`
- Next candidate source binary binding: `pending-new-build`
- Owned patchset status: `release-ready`
- Ported patch groups: `8`

The distributed application must also contain Chromium-generated third-party
notices and its generated SPDX SBOM. This summary does not replace either
artifact or a final legal review.

## Chromium

- Source: `https://chromium.googlesource.com/chromium/src.git`
- Tag: `150.0.7871.186`
- Commit: `0fcdce5f4fdec8d442d7df760cb541f1ca6e446d`
- License: `BSD-3-Clause`
- Packaged license: `NeAntikRuntimeLicenses/Chromium-LICENSE`
- License SHA-256: `368cca1106be99d39ecd32a38d8305585d802a475effb66380b91ffc9bcf709b`

## ungoogled-chromium-macos packaging source

- Source: `https://github.com/ungoogled-software/ungoogled-chromium-macos.git`
- Commit: `9cbd94c2b8f6f2a58a80bf32b3e01b68f3d129d4`
- License: `BSD-3-Clause`
- Packaged license: `NeAntikRuntimeLicenses/ungoogled-chromium-macos-LICENSE`
- License SHA-256: `2fdd1ed451121c07df0726a8ac8b86b49315d89a22c683edaf98b579e710504b`

## Common Chromium packaging source

- Source: `https://github.com/ungoogled-software/ungoogled-chromium.git`
- Tag: `150.0.7871.186-1`
- Commit: `fd0378e4f20fa09e21b09beca71573d435d787cf`

## Retained fingerprint-chromium attribution

NeAntik now applies the checked-in owned Chromium patchset from
`runtime/nevision-patches/series.json`. The BSD-3-Clause
fingerprint-chromium license remains bundled to preserve attribution for the
historical upstream implementation used to develop and validate this work.

- Packaged license: `NeAntikRuntimeLicenses/fingerprint-chromium-LICENSE`
- License SHA-256: `78bc4abfc3e5606b5b88c3cb9409a3250a7f64cffe704bef0563e11910a29189`

## NeAntik owned patchset

The release-required Chromium changes are the 8 ported groups
declared in `runtime/nevision-patches/series.json`. The release verifier binds
the packaged manifest and license files to the checked-in copies and separately
verifies the final source-built runtime, generated notices, and SPDX SBOM.

## Distribution boundary

This notice records source and license provenance only. `pending-new-build`
means it does not attest an existing binary; only a new build that records the
emitted source-provenance hash may change that boundary. Developer ID signing,
Hardened Runtime, Apple notarization, stapling, Gatekeeper, hosted-download
verification, and a qualified GUI A -> B -> A report remain separate release
gates.
