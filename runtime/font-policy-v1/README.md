# System font source policy — development

This development policy now includes a Chromium source patch; its seven changed
objects compile, but a full runtime has **not been linked or qualified**. It does
not alter the published runtime or existing profiles. The
[native result](../../docs/evidence/font-origin-development.json) is not a
browser or release qualification. See also the
[Chromium object result](../../docs/evidence/font-policy-chromium-objects.json).

`chromium-host-font-policy.json` is a frozen **input** manifest. It records the
exact prepared patch and expected pre/postimages; it is not a mutable release
status. The patch applies after the existing qualified M156 NeAntik source
stack, not directly to a clean upstream Chromium checkout. Existing source
contracts and compiled release archives are preserved.

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

1. Link and qualify the prepared patch covering family/local/unique lookup,
   fallback, Canvas/Offscreen, Font Access and Skia host paths.
2. Prove styles, restricted collection membership, variations, downloaded fonts
   and sandbox compatibility in actual native/browser operations.
3. Persist an explicit policy version. Old/imported profiles stay native until
   user opt-in; require a matching runtime capability before enabling it.
4. Add a bounded renderer-local QA witness, then run actual headed
   configured/unconfigured canary controls. Ordinary Chrome does not use the
   content_shell test-font initialization hook. A helper's process-local font
   does not automatically appear in a renderer child. Full PostScript
   collision, variable fonts and other macOS environments remain open.
5. Qualify the exact signed runtime/candidate before release claims.

All five final integration gates remain open despite passed compilation.
WebKit is outside this policy.

## Manager metadata — development, not activated

The manager now has a separate `fontPolicy` request (`native` / `system-v1`).
Missing legacy fields remain native; explicit null/unknown values stop loading
without replacing metadata from an older recovery snapshot. A nonnative request
requires the v4 workspace envelope, which older managers refuse. The launch
snapshot includes the policy. Copies, portable imports, metadata snapshots and
templates create native requests with fresh identities; full BrowserData restore
is a separate operation.

No runtime capability, environment emission, UI or MCP opt-in is enabled. The
current process boundary refuses `system-v1`, and WebKit refuses this Chromium
policy. The ordinary manager regression passed:173 Swift suites plus1501
Python contracts and30 focused workflow controls. Disabled/native fixtures are
not counted as executed. See [manager scope](../../docs/evidence/font-manager-development.json).
This is not a qualified or released font policy.


## Fixed browser/renderer QA witness — prepared

`chromium-font-witness.json` is a separate input contract applied after the
original policy patch. Its text delta and two NeAntik-original TTF resources
are separate from the frozen policy manifest. GN generation and four target
header checks passed. The new objects are **not compiled or linked**; resource
admission stopped before execution. [Current scope](../../docs/evidence/font-witness-development.json).

The QA seam accepts only `NEANTIK_FONT_QA=owned-v1`, a32-hex correlation nonce,
and an existing private nonce-bound temporary root. The root has fixed
`profile`, `crashes`, `marker` and `witness.log` entries. Browser-side checks
retain directory/file identity, reject symlinks/ACLs/flags/permissive modes,
and refuse managed-policy redirection before a default profile can be created.
Marker/log opens are nonblocking so malformed FIFOs cannot hang admission.
The requested CDP pipes are checked before opening any new descriptor.

The browser supplies a fixed Crashpad directory and requires stderr logging.
Sandboxed children compare the browser-approved profile path without reopening
the temporary marker. The renderer reads only fixed signed-bundle resources,
checks SHA256 and registers them in its own process before the default font
cache. There is no font installation, arbitrary resource loader, new sandbox
grant, user-facing option or MCP tool. An acknowledgement has only nonce, PID,
role and fixed completion/selection booleans; it is correlation, not authority
against the same OS user. The harness still needs kernel process custody and
exact-runtime pins.

Future actual qualification must include no-seed and configured sessions on
the same candidate, positive native selection of both canaries, repeat/crop
metrics, actual fallback/style/custom collection/WOFF2 operations and Font
Access permission behavior. Missing acknowledgements, contexts, resources or
completion never imply PASS. Malformed-root/FIFO, managed-policy redirection
and missing CDP-pipe controls must terminate without touching default data.
Those operations have not run. Ordinary manager, old primitive and old7object
receipts remain valid for their unchanged scope; this new seam needs its own
compile/link/headed gates.

Offline input verification (not runtime qualification):

```sh
python3 -B scripts/runtime-platform/verify-font-witness-inputs.py
python3 -B -m unittest scripts.tests.test_font_witness_inputs
```


### Actual registration experiment

A single authorized CoreText probe compiled once and ran three isolated cases.
In-memory descriptor registration was unavailable for both the unique and
family-collision fixtures on this Mac. Process-scoped URL registration of an
original font with a full PostScript-name collision succeeded; the selected
own face was rejected by the source policy and unregistered. All three fresh
observers found no exposed own face. [Results](../../docs/evidence/font-registration-development.json).
This supports the fixed bundle-resource design. It does not prove renderer
sandbox behavior or replace drawing, browser, compilation or release gates.
The one-off warning exception is consumed and does not apply to Chromium QA.
