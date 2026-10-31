# Privacy20 re-audit — 2026-11-01

Published NeAntik0.9.2(202), Chromium156.0.8078.80, product source a90a934. The signed app, ZIP/DMG, runtime and website were not changed. This audit corrects the earlier overly broad interpretation of “19implemented”: **9 requirements are fulfilled within their stated bounded scope, one is research-complete, ten remain partial**. Two P1 defects were found: custom-policy passport wording and framework signature admission in the updater; no confirmed production P0 bypass was found in the reviewed scope. This is not a claim that the product has no bugs or guarantees anonymity.

## Corrected qualification

- Old STUN comparison changed both RTC policy and LAN denial. The corrected owned fixture keeps LAN identical/unset and changes only RTC policy: control1UDP packet versus proxy-policy0. This does not prove successful proxied TURN media.
- Old service-worker check recorded registration only. New A1/B1/A2 probes verify registration pre-state, SW-message-owned persisted markers and dedicated-worker-owned IndexedDB state.
- Old media proof covered denied permissions only. New synthetic fake-camera/mic probes verify per-profile deviceID separation and persistent same-profile IDs with first-party cookies. groupID is stable within a document and rotates between documents. Reserved default/communications aliases are excluded. FakeUI auto-grants are not saved user-grant qualification. Physical devices and real profiles were not used.

All new cases passed against the same pinned signed executable/framework. Successful temporary browser roots and synthetic TLS keys were removed. Detailed sanitized evidence is in [the JSON receipt](evidence/privacy20-reaudit-20261101.json); raw nonce/device observations remain private.

## Requirement-by-requirement result

| # | Status | Confirmed | Remaining boundary |
|---|---|---|---|
| 1 | partial | Required proxy fixed in profile/system contexts; worker HTTP, keepalive, page WSS, downloads and failure/recovery. | Packet-wide DNS/UDP/IPv6 and ordinary background traffic remain unqualified; fixture disables background networking. |
| 2 | partial | RTC-off and corrected single-variable STUN comparison: control UDP1, proxy policy UDP0. | Successful proxied TURN/media and route qualification are not measured. |
| 3 | partial | Signed bounded downloader, reviewed runtime pins and migration/rollback boundaries. | Published202 updater refuses the normal flags0 Chromium framework at signature.policy; manual update required. No measured delivery SLA or future-version qualification. |
| 4 | partial | CERT/HaGeZi domain protection and threat-priority controls. | Google Safe Browsing and downloaded-file malware scanning remain disabled/absent. |
| 5 | fulfilled-bounded | New profiles start at local about:blank; saved URLs preserved. | This does not disable all browser background traffic. |
| 6 | fulfilled-bounded | Cookies/localStorage/IndexedDB/CacheStorage plus new service-worker registration/state and dedicated-worker IndexedDB A/B/A. | Bounded owned-origin/profile tests; no universal assertion for every storage API. |
| 7 | fulfilled-bounded | HTTP disk cache, socket reuse and TLS1.2 separation with positive controls. | TLS1.3, HTTP2 coalescing, HSTS/Alt-Svc and HTTP3 not independently measured. |
| 8 | partial | Native LNA block and literal/local-name preflight, including mapped IPv6. | Hostname-to-private/rebinding needs a controlled resolver test; remote proxy DNS remains a trust boundary. |
| 9 | fulfilled-bounded | Coherent Balanced/Strict presets, legacy preservation and compatibility gates. | Existing saved profiles retain their settings. |
| 10 | research-complete | Site-scoped derivation investigated; legacy31-bit seed is not a cryptographic secret. | A new Keychain-root/site-secret algorithm is not enabled. |
| 11 | fulfilled-bounded | WebGL debug-renderer extension hidden; normal rendering smoke passed. | Other GPU limits/rendering differences are not normalized. |
| 12 | partial | Protected system-font lookup/fallback, CoreText source checks and seven language vectors. | Not a universal eight-font bundle; browser-origin canary/full browser glyph fallback remain unverified. |
| 13 | fulfilled-bounded | Optional viewport grid200x100. | Fullscreen, DevTools and animated resize exemptions; outer window is not universally normalized. |
| 14 | partial | Strict permission denial plus new fake-media deviceID profile separation and document-specific groupID rotation. | Fake UI auto-grant does not prove persisted per-profile user permission grants; no physical camera/mic test. |
| 15 | fulfilled-bounded | 77852-domain HaGeZi filtering, bounded session exceptions and independent CERT priority. | Known-domain filtering does not block every possible tracker. |
| 16 | partial | Known all-tracking main-frame GET query cleanup and Chromium DIPS; synthetic OAuth/signed preservation. | Mixed queries preserved; not a universal redirect remover; real OAuth/payment flows not measured. |
| 17 | fulfilled-bounded | Two manager-driven ephemeral cleanup cycles and selected-profile clear; persistent data preserved. | Downloads remain; no SSD forensic-erasure guarantee. |
| 18 | fulfilled-bounded | Separate extension data, requested-permission warnings, Sync/autofill/password filling restrictions. | Component/external integrations may remain; native fixed proxy is an independent boundary. |
| 19 | partial | Encrypted backup58 source tests plus separate signed real-Keychain export/restore/wrong-password/corrupt/crash recovery. | Same Mac/profile/exact runtime only; exact production GUI and real browser-login restore not measured; not portable to another Mac. |
| 20 | partial | Passport distinguishes settings, sent parameters, recognized signed runtime and observations/unsupported surfaces. | Published0.9.2 wrongly claims Sync/autofill off for valid custom disableSyncAndAutofill=false. Source fix/14tests passed, not yet in a new signedbinary. |

## Documentation reconciliation

1. runtime/privacy-policy-v1/README.md incorrectly described the final manager/release as unqualified: corrected while retaining original intermediate receipt statuses.
2. runtime/font-policy-v1/system_font_source.h contains a historical pre-integration comment. Its pinned source snapshot is preserved; the current README explains the subsequently wired Chromium bridge.
3. The dated operator research called the31-bit seed a local secret: corrected. It is not a cryptographic root secret.
4. “Eight font objects” means compiled consumer objects, not eight visible fonts. The protected descriptor receipt is host-specific, not a universal fixed cohort.
5. The old worker-registration and confounded STUN observations cannot stand in for the newly measured stronger assertions. Their original receipts remain unchanged.
6. Fixture background-network suppression is not normal-launch background qualification.
7. Whole media-array inequality was weaker than complete identifier separation. Assertions now require empty device/group set intersections, with nonempty positive controls. Existing three-phase native observations passed the stronger checks offline; no extra browser launch was required.

## Concrete passport defect

Published0.9.2 always says Sync/autofill are disabled for non-legacy profiles,
although custom disableSyncAndAutofill=false is supported and the real launch
restrictions are conditional. Standard Balanced/Strict presets are unaffected.
The defect was reproduced before the fix. Conditional configured-intent text
passed14tests in2suites without skips. This is a source fix, not a claim that
already downloaded0.9.2 binaries have changed.

## Remaining implementation / acceptance work

P1: qualify normal background/DNS/UDP/IPv6 routing, successful proxied TURN, hostname-to-private LNA/rebinding, and saved permission-grant A/B separation; establish a measurable Chromium security-update release cadence.

P1/P2: browser-origin font canary/glyph fallback; real OAuth/payment-preservation journeys; exact production backup GUI with real synthetic browser state after restore. Broader threat/file scanning and redirect cleanup require explicit designs and compatibility checks. Do not silently weaken current safety boundaries to make these tests pass.

The additional SHA256 updater certificate pin remains an **unreleased source change**, not a fix already present in0.9.2. No new manager/helper binary release is claimed by this audit.

Chromium156.0.8078.80 corresponds to the [official2026-10-29 Stable/ExtendedStable announcement](https://chromereleases.googleblog.com/2026/10/stable-channel-update-for-desktop_02107719452.html). This does not prove a future update SLA or qualify a new Chromium tuple automatically.

## Concrete updater defect found during candidate qualification

The authentic public202 updater rejects the prepared signed candidate at signature.policy before installation: it incorrectly applies the executable CS_RUNTIME flag requirement to the Chromium framework dylib, whose normal signature uses flags0. Independent Security.framework observations verify valid deep/strict signatures and certified timestamps for all three roles; manager/runtime retain their expected executable hardening. Chromium installer signing/parts.py explicitly treats dylib option flags as meaningless. Re-signing the framework is not a compatible bridge because public202 also pins its exact original runtime closure.

The new role-specific policy permits framework flags0 or CS_RUNTIME, still requires empty framework entitlements, fixed Developer ID/team/identifier, timestamps, strict nested signatures and exact runtime provenance. Its hardenedRuntimeVerified observation now reports the actual bit. Manager/runtime missing that bit and framework ad-hoc/extra flags are negative controls. Targeted scalar tests and native Security.framework inspection of all three actual signed roles passed; this does not yet qualify a newly built shipping helper. Public202 requires manual ZIP/DMG installation of the future qualified release.

The opt-in signature test also hardcoded the historical runtime. It now accepts an explicit expected runtime version, without treating a version mismatch as signature success. The earlier candidate is retained as unqualified; no public archive was replaced.
