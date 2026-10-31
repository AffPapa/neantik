# Profile privacy policy v1 — development only

Four native consumer changes compiled in an isolated APFS clone of the V1011
recipient source. No relink, native runtime qualification or new release yet.
Do not mutate the published source/output or treat compilation as capability
admission. Source preimages are retained under the delta root identified in
source-bindings.json; the combined patch contains exact old/new source hunks.

The old31-bit fingerprint seed uses PersistentHash and has no site context.
It is not a cryptographic root secret. Item10 investigation is resolved as:
retain current identity compatibility; a future scoped-secret design must use
a separate Keychain root and explicit site/session boundaries, qualified across
frames/workers. Do not merely concatenate an origin to the old seed or expose
profile UUID/seed as a web identifier. No such new identity scheme is enabled.

Bundled site-protection source is in Resources/SiteProtection. It is not wired
to the manager/package yet. Its fixed public manifest.key is only an unpacked
extension identity; generated temporary private material was not retained.
The startup native-matcher gate remains open and must be qualified before
claiming first-navigation protection. Static/DNR activation is not proven by
these JavaScript unit tests.
