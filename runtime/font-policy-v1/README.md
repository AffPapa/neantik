# System font source policy — development

This development policy now includes a Chromium source patch; its seven changed
objects compile and a coherent runtime is linked. Its separate research copy is
Developer ID signed; **five headed page/worker modes passed; broader font and release qualification remain open**. It does
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

The bounded page/worker witness gate passed; full integration gates remain open.
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


## Fixed browser/renderer QA witness — bounded headed behavior verified

`chromium-font-witness.json` is a separate input contract applied after the
original policy patch. Its text delta and two NeAntik-original TTF resources
are separate from the frozen policy manifest. GN generation and four target
header checks passed. Four new/changed objects and the full runtime now compile
and link in a separate output; the previous runtime is preserved. The separate
research copy is signed with the existing Developer ID. All16 Mach-O files,
948 bundle entries and both fixed font assets were checked without launching
the browser. A later normal-resource headed attempt reached browser/renderer
selection ACK and page drawing, but failed on worker fixture startup and
QA cleanup inheritance. A separate successor patch corrects the non-profile
cleanup role and its QA environment. The corrected signed copy passed five
headed page/worker modes with actual cleanup and unchanged full runtime inputs.
[Headed results](../../docs/evidence/font-headed-development.json) cover that
bounded research scope; full release qualification remains open.
[Current scope](../../docs/evidence/font-witness-development.json).

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
Nine actual early-refusal cases passed on this same signed runtime: both
FIFO paths, profile symlink, permissive root, invalid marker, raw path redirect,
forged caller approval, invalid request version and missing pipe descriptors.
Each returned the exact unsupported-parameter exit13 without timeout, font ACK,
owned profile/crash data or residual processes. The absent raw redirect target
was not created. [Bootstrap evidence](../../docs/evidence/font-bootstrap-development.json).
Forced macOS managed policy is a different branch and was not mutated/tested
on the user machine; it remains an isolated managed-environment gate. Ordinary manager, old primitive and
old7object receipts remain valid for their unchanged scope; successful new
compile/link checks do not replace the pending headed and release gates.

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


### Finite headed fixture — five modes passed, full scope remains open

`run-font-policy.mjs` uses only a separately signed, private research bundle,
owned temporary profiles, mock Keychain and navigation-only pipe CDP. It pins
the whole runtime transcript, every Mach-O file, both font resources and its
source modules. The five modes are native, seed without policy, and policy
A → B → A with the same A profile reopened. Each browser/renderer must provide
a complete native selection witness bound to the owned process.

The fixture measures actual page and DedicatedWorker FontFace loads, Canvas
drawing, DOM metrics, styles, fallback and downloaded TTF/WOFF2 advances.
It does not use `document.fonts.check()` as font-presence evidence. Offline
synthetic controls prove the analyzer rejects missing contexts, truncated
results, local-font leakage, broken rendering and changed A results. They are
not runtime results. This fixture alone does not cover all nine contexts,
Font Access permissions, custom collections or the full release gate.

The first real attempt stopped after native mode. Its fresh worker waited for
`FontFaceSet.ready` before starting a font load; Chromium's worker starts with
a pending ready promise. The corrected fixture initiates a real URL load cycle
and still requires ready completion before measuring. The first attempt also
revealed inherited QA guards blocking Chromium's code-clone cleanup helper.
The old report remains failed; source correction, owned cleanup and subsequent
runtime results are separate evidence. No success criteria were removed.

Native admission remains fail closed. A research operator may supply an
explicitly approved, private one-shot warning-phase record bound to this exact
controller and runtime binding. It is atomically consumed, expires within five
minutes and admits only the five declared modes. Critical/unknown pressure and
serious/unknown thermal state still refuse. This does not change manager
admission or turn a failed observation into PASS; no such permission record is
created from a previous CoreText-only approval.

The corrected five-mode capture passed2,050 behavior assertions and168 A→B→A
checks at normal resource pressure, without a warning exception. Default
multiword Canvas and DOM measurements remain observations: their shaping
contexts can differ. The equality gate uses explicit no-kerning typography
and the unchanged0.08 CSS-pixel tolerance. Per-word measurements independently
show the boundary difference. CSS computed-value serialization is normalized
only for exact zero-spacing/lowercase equivalents; raw observations are kept.
Negative tests catch leakage in either default or matched typography.
No manager activation, ordinary Chrome comparison, full nine-context font gate
or released font-policy claim follows from this result.


### Standalone worker generic defaults — separate successor

`chromium-font-generic-defaults.json` is a frozen prepared input, not current
build status. Its four-file patch fills seven empty COMMON generic defaults
only for explicit system-v1 and a valid seed. Existing/per-script mappings are
preserved. It uses macOS defaults from the hash-pinned Chromium resource;
it does not claim full localized/custom preference propagation.

Two C++ objects were rebuilt in188seconds. A separately signed successor passed
four headed modes in the font-only nine-context fixture: eight drawing realms,
AudioWorklet API absence plus actual processing, independent creation/destruction,
OOPIF parent/context binding, real about:blank, and A→B→A. Native Shared/SW empty-map
fallback differences remain an observed negative, never a native coherence PASS.
[Exact scope](../../docs/evidence/font-nine-context-development.json).

`run-font-contexts.mjs` requires all five source contracts and the exact signed
code/full-tree closure. The original four-contract fixture and prior receipts
remain intact. This is research qualification, not manager activation or release.
Font Access, style/collection coverage and exact candidate gates remain open.


### Actual Font Access — own-name permission/blob stage

The signed five-contract research successor passed five headed modes: native,
seed-only, policy A/B/reopened A. Queries contain only three known names and one
invented missing name. Native returns both own fixtures plus the fixed system
control; configured policy returns only the system control. Denied/revoked new
queries return empty, while retained FontData blobs remain usable as upstream
specifies. Real SFNT parsing, own stable-table equality, FontFace load/draw and
cleanup passed. System blob bytes/hashes and inventory never leave the page.

CDP permissions are explicitly bound to the disposable BrowserContext and
nonce-confirmed top-level A. Chromium uses top-level origin for these overrides;
this is not independent embedded-origin-pair isolation. Explicit iframe
PermissionsPolicy delegation is observed as allowed. A distinct visible
standalone B in that same context remains ungranted and its actual request fails.
Late replies and stale/isolated/child contexts cannot restore permission authority.
[Scoped result](../../docs/evidence/font-access-development.json).

The first capture retained a failed harness expectation about iframe delegation;
source diagnosis corrected that model and added a genuine standalone negative.
No runtime rebuild, earlier nine-context replay or manager regression was needed.
Native permission-dialog UX, remaining collection/variation scope and the exact
shipping candidate are not claimed by this result.


### Restricted Skia collections and real variable instances

The finite direct Skia executable now passes six cases in separate native and
policy processes, followed by a fresh cleanup observer. It uses the real patched
Skia and policy archives, process-only own-font registration and physical file
identity. Mixed/empty/single-member collections preserve policy boundaries;
normal/bold/italic traits and actual drawing are measured. Native collection
widening remains a sensitive negative control.

This found a real false refusal: an allowed protected UI base's two actual
variable-weight clones drew correctly but failed source validation. The new
independent `chromium-font-variations.json` layer reconstructs its counterpart
from the protected file with supported finite coordinates, preserving file
identity, actual face, effective coordinates and every-table comparison. The old
exact-face proof remains. Both real clones now pass; different weights produce
different stable rasters. [Evidence and failed-baseline scope](../../docs/evidence/font-skia-development.json).

The source policy object and QA executable were compiled in a separate APFS COW
output. Original objects, five frozen manifests and the earlier signed browser
were preserved. This is not a newly linked headed browser or a release. The
six-layer runtime still needs its relevant browser gates, manager opt-in and
exact-candidate qualification. No earlier browser PASS is transferred to it.
