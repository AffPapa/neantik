# Same cohort, different profile data

The exact downloaded135 runtime ran two synthetic seeds,11 and22, which map
to the same reviewed M1 hardware cohort. One own HTTP origin stayed fixed
through four serial sessions:

1. A writes own random markers in persistent cookies, LocalStorage, IndexedDB
   and CacheStorage and activates an own Service Worker. SessionStorage is
   also written but must not reappear in a fresh top-level session.
2. A deliberate wrong-root control uses A's directory with B's seed. The
   fixture detects existing A data and refuses to overwrite it. This is a
   sensitivity control, **not** a claim that Chromium refuses a user-supplied
   directory or that the manager's identity guard was tested here.
3. The actual B directory starts empty and stores its separate marker.
4. A returns with its original seed, HTTP cookie and all persistent stores.
   Its own marker remains unchanged; SessionStorage starts empty.

All four real browsers closed normally, helpers exited and both temporary
profiles/server were removed. Mock Keychain and a sanitized environment are
used; no ordinary profile, user cookie or production identity is opened.

## Retained failure and offline correction

The initial producer reported FAIL because its final verifier incorrectly
required different Canvas hashes for every seed. The own vector drawing
matched across seeds. The M156 source replay contains `semantic:canvas`, whose
verified patch removes readback/image-encoder noise to preserve API semantics.
Item17 requires separate configuration identity/data and stable cohorts; it
does not require unique pixels from every API. The old documentation's claim
that seed values always make Canvas/Audio/WebGL/ClientRects distinct was stale
and has been corrected.

The original failed capture and producer/verifier bytes remain unchanged.
`analyze-isolation.mjs` accepts only that exact unsupported-uniqueness failure;
all storage, cohort, seed, repeat, process and cleanup checks remain required.
The producer also mislabelled the verification error as `cleanupFailure`;
future code records it separately. An offline timestamp check initially used
strictly separated milliseconds. Two serial sessions shared their boundary
millisecond; finite, non-overlapping times plus the retained sequential-await
and process0 source are now checked. No browser was rerun for either fix.

```sh
node scripts/runtime-cohorts/test-isolation-verify.mjs
node scripts/runtime-cohorts/run-isolation.mjs /absolute/runtime.app /absolute/binding.json /absolute/fresh-output
node scripts/runtime-cohorts/analyze-isolation.mjs /absolute/binding.json /absolute/retained-initial-failure
```

The exact correction analyzer targets the retained first producer; it is not
a generic way to turn future failures into PASS. Three modeled positives
accept both equal and different Canvas output and equal boundary milliseconds;
23 negative mutations must reject, including a leaked cookie, lost cache,
restored sessionStorage, changed seed, wrong runtime or missing cleanup.
The same23 mutations reject against the actual captured scenario offline.

This covers raw Chromium user-data roots on one Mac. It does not qualify
manager-mediated creation, WebKit, parallel-session behavior, all OS-encrypted
secrets or every hardware/OS. The remaining1.0 gates keep their own scope.
