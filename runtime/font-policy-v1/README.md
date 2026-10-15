# System font source policy — development

This CoreText building block is **not connected to Chromium**. It does not
alter the published runtime or existing profiles. The
[native result](../../docs/evidence/font-origin-development.json) is not a
browser or release qualification.

## Behavior

`SystemSourcePolicy` admits a host font only when its resolved file is in the
protected system font directory and all SFNT tables match a face opened from
that same file. Family names, PostScript names, URL attributes and registration
priority alone do not prove origin. OS asset paths are classified separately,
without automatically trusting them. The cache retains immutable CTFont
objects and is bounded to 32 entries.

The policy finds protected family/face descriptors and a fallback covering a
bounded text request. LastResort is not real glyph coverage. Every constructed
candidate still needs validation. Callers retain the existing renderer style,
weight, slant, variation and shaping behavior.

Apply this to **host lookup only**. Downloaded CSS fonts and explicit
FontFace/byte resources keep their ordinary drawing path.

## Owned native test

Use a private Python environment with the hash-pinned
`scripts/runtime-platform/requirements-font-qa.txt`. FontTools is QA-only.
Create a fresh private output directory and pass absolute paths:

```sh
python3 -B scripts/runtime-platform/run-font-origin-probe.py \
  /absolute/private/empty-output /absolute/private/venv/bin/python3
python3 -B scripts/runtime-platform/analyze-font-origin.py \
  /absolute/private/empty-output
python3 -B -m unittest scripts.tests.test_font_origin
```

The driver checks native readiness and active compilation first. Original TTF
fixtures register only in the QA process, never the user/session inventory.
The test requires actual family-collision selection, refusal and a drawn
system replacement. Seven samples cover Latin, Cyrillic, CJK, Arabic,
combining marks, colour emoji and a variation selector. Bitmap drawing,
missing glyphs and LastResort are checked separately. Receipts preserve source
copies, hashes, failures and exit status. Output contains counts/categories,
without printing the user's font inventory. Missing context, source drift,
timeout or failed cleanup never passes the offline analyzer.

## Before enabling in NeAntik

1. Connect one traceable Chromium patch to family/local/unique lookup,
   fallback, Canvas/Offscreen, Font Access and Skia bypasses.
2. Preserve styles, variations, downloaded fonts and sandbox compatibility.
3. Persist an explicit policy version. Old/imported profiles stay native until
   user opt-in; require a matching runtime capability before enabling it.
4. Run actual headed configured/unconfigured canary controls. A process-local
   font does not automatically appear in a renderer child. Full PostScript
   collision, variable fonts and other macOS environments remain open.
5. Qualify the exact signed runtime/candidate before release claims.

All five integration gates remain open. WebKit is outside this policy.
