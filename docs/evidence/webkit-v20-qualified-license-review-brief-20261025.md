# NeAntik 1.0 WebKit licensing review brief

Status: **prepared for qualified review; not submitted and no legal decision is recorded**.

## Exact review subject

- Product candidate: NeAntik 1.0.0, build 139, candidate `f3488c08f0b3493dbcee8db94473bacf`.
- Frozen bundle inventory SHA-256: `026d6b343ef5c595aa943a2fafadc72ca55ab6f3597f10fbff7d4e85a3858c51`.
- WebKit source commit: `43d5b8d85e2e5eed41d7ff8a79da831bf405be6c`.
- Private source-offer manifest SHA-256: `c45c9851a174c81b79664ab89a27f8fcf8638fae874a47c3f5b327019b7dde00` (132 components).
- Unresolved rows: 82 total — 4 runtime images and 78 packaged resources.

The row-by-row packet is [`webkit-v20-license-review-packet-20261025.json`](webkit-v20-license-review-packet-20261025.json), SHA-256 `99ec10c609b5a91a2c1b5146295570fea755920ce37a4ae98c71eb529c0ee9e6`. It binds each row to the runtime image/resource hash, current exact v20 compile-input source map (SHA-256 `70a07ede311458659ba1a9d5b91a90a6bfbd130d809dfe19865bc684cf952f6a`), and WebRTC upstream notice metadata where applicable (SHA-256 `58728eace4ccaa0ab0c22b6322025f7fc36094466cf7328829ad8b08720bfa96`). It intentionally retains every unresolved worksheet decision as `UNKNOWN`; exact input matches, header markers, and nearby license texts are evidence leads, not applicability decisions.

## Technical map of unresolved clusters

These counts prioritize review; they do not determine which license applies. Each row hash and evidence path is in the JSON packet.

| Runtime image | Exact compile-input source rows | Header signals in those inputs | Nearby candidate license texts |
| --- | ---: | --- | --- |
| `JavaScriptCore` | 35/35 | 11 Apple BSD-form; 1 MPL | `Source/JavaScriptCore/COPYING.LIB` (9); `Source/JavaScriptCore/disassembler/ARM64/LICENSE-binja.txt` (1) |
| `WebCore` | 142/142 | 86 Apple BSD-form; 3 GNU Lesser GPL | `Source/WebCore/LICENSE-APPLE` (25); `LICENSE-LGPL-2` (25); `LICENSE-LGPL-2.1` (25); `PAL/ThirdParty/dav1d/COPYING` (58) |
| `WebKit` | 29/29 | 11 Apple BSD-form | none detected |
| `libwebrtc.dylib` | 2505/2505 | 343 Apache; 247 Apple BSD-form; 1 MIT-like; 1 MPL-2.0 | 17 README.chromium records and 8 license/patent files inventoried separately |

Resource rows: 78 remain UNKNOWN (60 WebCore with three nearest candidate texts, 14 with no candidate text, 3 WebKitLegacy, 1 JavaScriptCore). Across all 84 packaged resources, 62 are byte-identical to one mapped source file; that fact does not establish license applicability. The WebRTC notice candidate separately pins 40 source/notice paths; 33 match the current text corpus and 7 are AUTHORS entries outside it. This is package-coverage evidence only.

### Follow-up evidence for the WebKit image

The exact v20 source/build review found one WebKit-framework primary source with no open-source license text in its header. It is textually included in the unified translation unit, but `WK_WEB_EXTENSIONS_BOOKMARKS` is disabled by this exact build configuration; matching bookmark implementation symbols were absent from the exact framework image and unity object. See [`webkit-v20-bookmarks-conditional-source-review-20261025.json`](webkit-v20-bookmarks-conditional-source-review-20261025.json). This narrows the runtime-image evidence only: it does not license the source file, classify the other 17 header-unmarked inputs, or close the `WebKit.framework` row. WebKit's official guidance confirms its source contains BSD and LGPL files and requires retaining the original per-file license when moving code ([Licensing](https://docs.webkit.org/Other/Licensing.html), [WebKit licensing page](https://webkit.org/licensing-webkit/)).

## Decisions requested

For each of the 82 rows, please record:

1. Copyright/licensor and applicable license for the exact distributed bytes, including whether generated or transformed output changes the analysis.
2. Required notices, their exact text, and where they must appear in the app and source offer.
3. Corresponding-source, modification, relinking/replacement, and reverse-engineering terms that apply to the hardened macOS package.
4. Any item that must be replaced or excluded before redistribution, with the specific reason and a viable replacement path.
5. Whether the pinned source/build material is sufficient for the required offer, or which exact source, scripts, dependency, or build input remains missing.

Please return row-specific outcomes using the worksheet fields (`applicableLicense`, `noticeLocation`, `requiredNotice`, `reviewerDecision`) and include reasoning/source references for each decision. A nearest license filename, a header marker, source-byte equality, or a maintainer evidence note is supporting evidence only; none is a substitute for your applicability decision.

## Boundary

This brief is an internal review request. It is not legal advice, a license approval, release authorization, or a public claim. No reviewer has been contacted. The frozen candidate, current public alpha, signing identity, and publication channels are unchanged.
