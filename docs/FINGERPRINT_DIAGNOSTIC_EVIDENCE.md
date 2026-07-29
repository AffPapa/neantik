# NeAntik fingerprint diagnostic evidence

## Scope

On 25 July 2026, the exact production `FingerprintAuditCoordinator` and
JavaScript probe completed four real three-pass audits against source-built
Chromium `headless_shell` targets from the pinned NeAntik Chromium tree. The
latest two use the target rebuilt from the normal Metal configuration.

The runs used an explicitly marked diagnostic execution mode:

```text
headless-single-process-diagnostic
```

That mode adds `--single-process --no-sandbox` only to the developer audit CLI.
The normal NeAntik GUI path remains the default `browser` mode and receives
neither argument. The CLI accepts diagnostic mode only for an executable named
`headless_shell`, and every saved JSON report records the execution mode.

This is real Blink/browser-visible behavior, but it is not production GUI
release evidence.

NeAntik 0.3.8 makes that boundary executable rather than editorial:
`headless-single-process-diagnostic` reports can still receive the engineering
verdict `verified`, but `isProductionReleaseQualified` is always false for
diagnostic mode. Production qualification also requires available and stable
WebGL pixels/vendor/renderer and different WebGL pixels between profiles.

## Result

All independent diagnostic runs returned `verified`.

The fixed identities were:

```text
Profile A: NA-XXXXXXXX
Profile B: NA-YYYYYYYY
Profile A: NA-XXXXXXXX
```

The critical and device values matched exactly across both complete runs:

| Surface | Profile A | Profile B | Profile A repeat |
| --- | --- | --- | --- |
| Canvas | `f33baf97` | `88f9231a` | `f33baf97` |
| Audio | `24e2d278` | `8150ed4c` | `24e2d278` |
| ClientRects | `eae5f5f0` | `90c063d1` | `eae5f5f0` |
| Hardware concurrency | `8` | `10` | `8` |
| WebGL pixels | unavailable | unavailable | unavailable |

Canvas, Audio, and ClientRects therefore differed across A/B and remained
stable for A. WebGL was honestly excluded from the verdict because neither the
no-Metal nor Metal-configured headless process exposed it. The full Metal app
still needs the production GUI report for browser-visible WebGL evidence.

The user agent in all captures identified Chromium `144.0.7559.132`, and the
same bare executable reports:

```text
NeAntik Browser 144.0.7559.132
```

`runtimeVersion` is `null` in these JSON reports because the runtime inspector
intentionally reads bundle metadata and the diagnostic target is a bare
`headless_shell`, not an application bundle.

## Evidence

Current Metal-configured report:

```text
artifacts/looper-goals/20260724-fingerprint-runtime/fingerprint-audit-headless-metal.json
SHA-256 2a28cd328006971c2a2638da85f176ebdf7d83ea6f0a13c1d68b66f24aa4fefb
```

Independent repeat:

```text
artifacts/looper-goals/20260724-fingerprint-runtime/fingerprint-audit-headless-metal-repeat.json
SHA-256 dab7ca364a3e054cf3825c336a9547b104bad6c818f2072d2f2ad935caea51e9
```

Both current reports are owner-only mode `0600`. The two earlier no-Metal
reports remain in the evidence directory as historical proof.

## Bug found by the behavioral run

The first diagnostic attempt exposed DevTools but failed to discover its page
target. Chromium serializes the target field as `webSocketDebuggerUrl`;
NeAntik's synthesized Swift decoder had expected `webSocketDebuggerURL`.

The decoder now has an explicit coding key, and a regression test uses a real
Chromium-shaped `/json/list` response. This correction applies to both the
diagnostic CLI and the normal GUI audit.

## Remaining release proof

The following are still required:

1. run the same A -> B -> A coordinator against the full source-branded
   `NeAntik Browser.app` in a normal user GUI session;
2. pass the strict production qualification gate, including WebGL pixels,
   vendor, renderer, and GPU metadata in that production GUI run;
3. sign with Developer ID, notarize, staple, and pass Gatekeeper;
4. complete user-context GUI QA and the Direct signing, notarization,
   stapling, Gatekeeper, and hosted-download gates.
