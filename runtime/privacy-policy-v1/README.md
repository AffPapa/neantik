# Profile privacy policy v1 — shipped in 0.9.2 with scoped qualification

Eighteen native consumer objects and five supplemental sources compiled and linked in an isolated APFS clone of the V1011
recipient source. Scoped native qualification is recorded in native-smoke-20261031.json;
that file is an intermediate development snapshot. The final signed manager and public0.9.2 are qualified in releases/v0.9.2.json; read docs/PRIVACY_MODES.md for scope and limitations.
Do not mutate the published source/output or treat compilation as capability
admission. Source preimages are retained under the delta root identified in
source-bindings.json; the combined patch contains exact old/new source hunks.

The old31-bit fingerprint seed uses PersistentHash and has no site context.
It is not a cryptographic root secret. Item10 investigation is resolved as:
retain current identity compatibility; a future scoped-secret design must use
a separate Keychain root and explicit site/session boundaries, qualified across
frames/workers. Do not merely concatenate an origin to the old seed or expose
profile UUID/seed as a web identifier. No such new identity scheme is enabled.

Bundled site-protection source is in Resources/SiteProtection. It is wired in the published0.9.2 manager and package; final qualification is recorded separately from the intermediate derivation receipts. Its fixed public manifest.key is only an unpacked
extension identity; generated temporary private material was not retained.
The native matcher blocked owned tracker/threat fixtures before the proxy.
Temporary site exceptions were added and removed through the real extension
API; threat rules retained priority. JavaScript unit tests alone do not prove this.

The derived layer now carries all eighteen exact pre/postimages and relative compile
recipes in derivation.json. Its retained derivation receipt status is compiled-and-relinked-unqualified: this describes recipient preparation, not the later public release. The
validator checks actual source/object bytes in the disposable recipient; default
verification requires the successful bounded link receipt already bound here. Archive membership projections and direct RSP inputs bind each of the eighteen objects.
Manager lifecycle source tests cover interrupted-session cleanup and refusal on
unknown process inventory; these do not establish native cache erasure.

The network-service URLRequest preflight rejects canonical private/nonpublic IPs,
localhost and local domain names before a URLLoader/WebSocket request is routed,
including redirect targets. It does not issue a DNS lookup. An arbitrary hostname
resolved to a private address by the upstream proxy remains a proxy trust boundary;
stock transport-based LNA alone does not prove this case blocked.

Build-only preparation and native execution have separate admission. The local
development skill explicitly allows serial bounded compilation/linking without
executing a probe during memory-pressure refusal; app/enrollment/headed QA still
requires production resource admission. Do not apply the launch gate to linking.


Packaging regression discovered during native qualification: the loose relinked
framework differed from the nested app framework consumed by signing. The
unsigned verifier now checks both, and privacy preparation supplies a nested
preimage digest to the signer before and after staging. Never infer signed
source binding from a loose framework hash alone. Retained failed prototypes
are diagnostic evidence, not capability records.

The query-cleanup regex uses one repeated exact key/value token to fit
Chromium RE2's2KiB limit. Static indexing and native matcher readiness were
observed with the factored expression; ordinary JavaScript RegExp acceptance
alone does not establish DNR support.

The18th existing object pins required proxy configuration in profile and system
NetworkContext creation. Normal extension installation restrictions remain useful,
but external/component loads and public ID reuse are not a route boundary.
A hostile own QA extension controlled proxy prefs and set DIRECT; the native
fixed service kept the selected route. An unprotected control instead failed DNS
for the synthetic origin. Malformed required protocol stops before context
creation and never falls back to DIRECT.

## Re-audit qualification boundary (2026-11-01)

The original native harness registered a service worker without checking its
persisted state and changed both LAN and RTC policies in its STUN comparison.
The supplemental QA cases in scripts/privacy20 now isolate the RTC variable
and measure SW-owned and dedicated-worker-owned state across A/B/A. Fake media
cases cover device-ID profile separation and document-specific group-ID rotation;
they do not prove saved user permission grants. See the separate dated re-audit
receipt for measured results; editing this README never upgrades an old receipt.

Eight font consumer objects does not mean eight visible fonts. The source policy
uses protected system descriptors and language fallback; it is not a universal
fixed font cohort across macOS versions. Historical development comments in
runtime/font-policy-v1/system_font_source.h predate the Chromium bridge and do
not describe current integration. Browser-origin font canary remains unverified.

The synthetic harness disables background networking for fixture isolation. Its
worker/keepalive tests do not qualify all normal browser background traffic,
packet-wide DNS/UDP/IPv6 paths or successful proxied TURN media.
