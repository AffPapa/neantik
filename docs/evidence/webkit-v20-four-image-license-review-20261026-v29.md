# NeAntik v1.0 four-image review — V29 correction

The V28 source review established that all 193 WebKit source-header rows match their pinned source and exact BSD-form notice blocks. A direct inspection of the immutable candidate-139 app then showed the linked-source notice bundle and Markdown/HTML section were not physically present. The V27/V28 installer test covered output generation in an isolated fixture, not the candidate app.

Therefore the candidate-139 `WebKit.framework/Versions/A/WebKit` row returns to UNKNOWN. This corrects V28's package-presence claim and does not change the source/header classification. Candidate 139 remains immutable, superseded, unqualified and unpublished. The worksheet again has 82 UNKNOWN decisions: 4 image rows and 78 resource rows.

Before resolving this row, a new frozen candidate must contain the exact source-header bundle and notice section, and its package bytes and signature must be verified. JSC, WebCore and libwebrtc remain UNKNOWN. Complete corresponding-source/relink, independent recipient replacement/re-sign/load, headed WebKit page-load QA, privacy/proxy/profile QA and publication remain open. No build, install, signing, notarization or publication occurred.

Correction receipt: `docs/evidence/webkit-v20-webkit-image-package-notice-audit-20261026-v29.json` (SHA-256 `eb15fc738e276ec266c0d2db2b2e3a77395ea95d0064cb802dbd261ee9d96dd3`).
