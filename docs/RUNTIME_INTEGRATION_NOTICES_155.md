# NeAntik Chromium runtime notices

## Source references

- Chromium: `155.0.8059.40`
- Owned patch groups: `73`
- Candidate lock SHA-256: `1b29f8cf8168d29f0b5534cb03267aff7c3e0416034c8e69cc3f56de266ba588`
- Source contract SHA-256: `5c1f8789fe9f586a075b98d29a969c62aa86cc8562b0c6a489fa9fc66a865716`
- Chromium: `https://chromium.googlesource.com/chromium/src.git` at `cfaadc5a132d78e1828635aa8405a499f3e14864`
- Common Chromium packaging: `https://github.com/ungoogled-software/ungoogled-chromium.git` at `37085e47cf580c815a30402917d350ce97399ded`
- macOS packaging: `https://github.com/ungoogled-software/ungoogled-chromium-macos.git` at `f7ba75f94442abda7ac3ea81790c217f8636d3ba`

## Bundled licenses

The hashes below identify the license files included with the application.
Chromium-generated third-party notices and the SPDX SBOM are also required.

- `NeAntikRuntimeLicenses/Chromium-LICENSE` — SHA-256 `368cca1106be99d39ecd32a38d8305585d802a475effb66380b91ffc9bcf709b`
- `NeAntikRuntimeLicenses/ungoogled-chromium-macos-LICENSE` — SHA-256 `2fdd1ed451121c07df0726a8ac8b86b49315d89a22c683edaf98b579e710504b`
- `NeAntikRuntimeLicenses/fingerprint-chromium-LICENSE` — SHA-256 `78bc4abfc3e5606b5b88c3cb9409a3250a7f64cffe704bef0563e11910a29189`

The fingerprint-chromium license is retained for historical attribution.
The owned M155 port is recorded under
`runtime/nevision-patches/ports/chromium-155.0.8059.40/`.

## Distribution boundary

These notices identify source references and bundled license bytes only.
They do not attest runtime behavior, security checks, signing, notarization,
Gatekeeper acceptance or publication. Those are separate release gates.
