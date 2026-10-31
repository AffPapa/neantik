# NeAntik Chromium runtime notices

## Source references

- Chromium: `154.0.8037.98`
- Owned patch groups: `73`
- Candidate lock SHA-256: `6b3ef68531e3005a629765fed61274817731e5e0468bc137d44b90d1697e39ff`
- Source contract SHA-256: `2ff506abc7ef6f47d86578bdc96b4615cb9722b342c8411bd235b1ac6d896f01`
- Chromium: `https://chromium.googlesource.com/chromium/src.git` at `b859317bf11f6be47f9b7799ec690a0a42a1fb33`
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
`runtime/nevision-patches/ports/chromium-154.0.8037.98/`.

## Distribution boundary

These notices identify source references and bundled license bytes only.
They do not attest runtime behavior, security checks, signing, notarization,
Gatekeeper acceptance or publication. Those are separate release gates.
