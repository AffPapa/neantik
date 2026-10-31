# Chromium compatibility qualification

This research harness tests representative codec operations and native PDF
rendering on the exact bytes named by a public NeAntik release report. It does
not build, replace, sign or qualify a new application release.

## Own inputs and observations

- `create-fixtures.py OUTPUT` creates red 64×48 videos (VP8, VP9, baseline H.264),
  a synthetic 440 Hz mono tone (PCM, Opus, AAC), two original vector PDFs and an
  invalid container. The existing local FFmpeg is used with two encoder threads;
  no assets or packages are downloaded. The manifest binds every input hash.
- `run-headed.mjs APP RELEASE_REPORT FIXTURES OUTPUT configured|unconfigured`
  verifies the report's executable/framework/manager hashes and runtime signature.
  It requires normal resource admission immediately before each owned browser.
  It uses a new temporary profile, mock Keychain, credential-filtered environment,
  loopback-only endpoints and blocked external proxy/DNS. No ordinary app or
  profile is used. The configured mode sets synthetic seed21; it does not exercise
  the manager launch path, all cohorts or the opt-in system-font policy.
- `probe.js` measures decoding and muted playback separately from `canPlayType`
  and MediaCapabilities declarations. Video must advance time, decode real frames
  and produce red output. Audio must decode the expected duration, sample rate,
  energy and tone, then advance its media element. Physical audio output, camera
  and microphone are not tested.
- PDF colour and white-page controls use a fixed crop of the fixture's own page.
  The CDP adapter accepts only exact nonce URLs and the fixed screenshot command;
  it never evaluates arbitrary JavaScript. An independently decoded PNG is
  normalized from its embedded ICC profile to sRGB. Native screenshots must be
  opaque before conversion. A missing or timed out context never passes.

The optional native PDF oracle requires the project's existing ARM64
`/opt/homebrew/bin/python3` with Pillow. That dependency is checked before browser
launch. Model tests without ICC do not require Pillow. The runner does not install
dependencies or use an old warning exception.

## Checks and preservation

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -B -m unittest discover -s scripts/tests -p test_runtime_compatibility.py
node scripts/runtime-compatibility/test-pipe.mjs
```

Every session saves source hashes, version/OS/architecture, observations, own
served-file hashes and cleanup. New runs also preserve source bytes in a private
input archive. Do not overwrite a result. An analysis correction writes a new
receipt against retained files; it does not silently replace a failed capture or
require another browser run. Public reports contain a small scoped summary,
never private runtime stderr, profile paths, raw IPs or system device lists.

The [0.8.20 result](../../docs/evidence/compatibility-0.8.20.json) includes both the
initial ICC false failure and its independent offline resolution. The six codec
profiles, two PDF documents and actual negative controls do not establish DRM,
MSE, all encodings/resolutions, WebKit or universal website compatibility.

API references: [Media Capabilities](https://www.w3.org/TR/media-capabilities/),
[HTML media](https://html.spec.whatwg.org/multipage/media.html).
