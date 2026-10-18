# Media Source Extensions: bounded runtime check

Checks fragmented H.264 and AAC playback on an exact published Chromium runtime.
It adds a missing part of major-plan item18; it does not repeat the existing
file-codec/PDF suite or qualify a new app release.

`create-fixtures.py OUTPUT` uses the existing local FFmpeg with two threads to
create two original two-second streams: red64×48 video and a440Hz mono tone.
A manifest binds the original MP4, initialization segment and four fragments
per stream. No download, microphone, camera or personal media is used.

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -B scripts/runtime-mse/create-fixtures.py /absolute/new/fixtures
node scripts/runtime-mse/test-verify.mjs
node scripts/runtime-mse/run-headed.mjs /absolute/NeAntik.app /absolute/release.json /absolute/fixtures /absolute/new/output configured
```

The second mode is `unconfigured`. Each run requires normal native resource
admission and uses a fresh private profile, mock Keychain, blocked external
proxy/DNS and its own loopback endpoint. The fixed compatibility pipe permits
only owned nonce pages; no arbitrary page JavaScript is evaluated by CDP.

The browser actually appends each hashed segment, waits for `updateend`, checks
buffer growth, ends the stream and plays it muted with advancing time. Video
must decode frames and show the expected red pixel. It then removes buffered
data and the SourceBuffer. Actual negative controls exercise unsupported MIME,
endOfStream while updating, invalid removal range, append to a detached buffer
and duplicate removal. Offline mutation controls prove rejection of missing
operations, wrong assets, wrong frames, fake success and incomplete cleanup.

Main-process close and helper drain are distinct. Record the close result and
wait up to three seconds for helpers to exit naturally before considering any
strictly owned process-group cleanup. An unbound process is never signalled.
Source hashes and private input bytes are preserved before launch. Failed
receipts are immutable; a subsequent run uses a new output directory.

## Observed scope

On the exact downloaded0.8.23 runtime, configured and unconfigured sessions each
passed60 operation checks and exited normally with no own process or profile
remaining. The first unconfigured capture passed the operations but failed an
overly early helper-cleanup assertion. That original failure is retained;
only this affected session was repeated after the harness correction.
[Minimized result](../../docs/evidence/mse-0.8.23.json).

This does not cover DRM/license exchange, adaptive bitrate switching, mixed
tracks, all codec profiles, network stalls, physical audio, WebKit, other Macs
or the full item18/major1.0 acceptance. No shipped executable changed.

Reference: [W3C Media Source Extensions](https://www.w3.org/TR/media-source/).
