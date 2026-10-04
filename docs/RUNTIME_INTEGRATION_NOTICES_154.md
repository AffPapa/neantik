# NeAntik Chromium runtime notices

## Source references

- Chromium: `154.0.8037.93`
- Owned patch groups: `73`
- Candidate lock SHA-256: `c8f08b79f0d620139da900f1afb892878a8443f4ddcfc93c1bbf647a5473579f`
- Source contract SHA-256: `db3b78fdb491d22904038e79de2b6ae20d98418b50ceae9f544528d1aeb7b155`
- Chromium: `https://chromium.googlesource.com/chromium/src.git` at `f89f3a4363808e117c592adedcf9947882ac3b79`
- Common Chromium packaging: `https://github.com/ungoogled-software/ungoogled-chromium.git` at `800d0bb5078472e4442c1fd73373172754a60939`
- macOS packaging: `https://github.com/ungoogled-software/ungoogled-chromium-macos.git` at `3241dc9cacee393621d277ec936376072f0cb3c5`

## Bundled licenses

The hashes below identify the license files included with the application.
Chromium-generated third-party notices and the SPDX SBOM are also required.

- `NeAntikRuntimeLicenses/Chromium-LICENSE` — SHA-256 `368cca1106be99d39ecd32a38d8305585d802a475effb66380b91ffc9bcf709b`
- `NeAntikRuntimeLicenses/ungoogled-chromium-macos-LICENSE` — SHA-256 `2fdd1ed451121c07df0726a8ac8b86b49315d89a22c683edaf98b579e710504b`
- `NeAntikRuntimeLicenses/fingerprint-chromium-LICENSE` — SHA-256 `78bc4abfc3e5606b5b88c3cb9409a3250a7f64cffe704bef0563e11910a29189`

The fingerprint-chromium license is retained for historical attribution.
The owned M154 port is recorded under
`runtime/nevision-patches/ports/chromium-154.0.8037.93/`.

## Distribution boundary

These notices identify source references and bundled license bytes only.
They do not attest runtime behavior, security checks, signing, notarization,
Gatekeeper acceptance or publication. Those are separate release gates.
