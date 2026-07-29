# Fingerprint runtime contract

NeAntik itself is a native profile and process manager. Browser-visible
fingerprint values are implemented by a compatible Chromium runtime, not by
JavaScript injected into pages.

## Required command-line protocol

A compatible runtime must support:

```text
--fingerprint=<positive signed-32-bit-compatible seed>
--fingerprint-platform=macos
```

NeAntik generates one stable seed in `1...2147483647` per profile. It does not
rotate that seed between launches, because a returning session with a
constantly changing device identity is internally inconsistent.

The current owned runtime parses this switch through Chromium's signed `int`
command-line conversion. NeAntik therefore never generates a high-bit
`UInt32` seed. Profiles written by older builds are repaired once on load:
high-bit values are folded into the supported positive range and any resulting
collisions are resolved before the repaired metadata is persisted. The launch
builder applies the same conversion defensively.

NeAntik deliberately does not guess CPU, GPU, screen, memory, or platform
version in the manager. Those values must be generated as one coherent tuple
inside the exact Chromium runtime and proven by the three-pass check. A
tag-specific GPU table cannot safely be assumed for an arbitrary compatible
runtime.

## Runtime modes

### Stock Chrome or Chromium

- Separate cookies, cache, local storage, and sessions.
- Separate proxy configuration.
- No claim that Canvas, Audio, WebGL, fonts, or hardware values differ.
- NeAntik does not send unsupported fingerprint flags.

### Explicitly compatible Chromium

- Receives the persistent profile seed and native macOS platform flag.
- The runtime, not NeAntik, is responsible for coherent Canvas, Audio, WebGL,
  font, ClientRects, WebRTC, language, timezone, and Client Hints behavior.

## Selection

1. Install the runtime independently from its official source.
2. Use the folder button in the NeAntik sidebar to choose the `.app` bundle or
   its Chromium executable.
3. Enable **Fingerprint-compatible runtime** only if the runtime documents the
   command-line protocol above.
4. The sidebar must show **Fingerprint protocol configured** before launch.
5. Run **Fingerprint Check** before treating the selected binary as verified.

NeAntik also detects externally installed Cloak Chromium builds under:

```text
~/.cloakbrowser/chromium-*/Chromium.app/Contents/MacOS/Chromium
```

NeAntik does not bundle or redistribute Cloak binaries.

## Privacy boundary

A distinct seed is necessary but not sufficient for anonymity. Proxy exit
location, DNS, WebRTC, timezone, language, screen geometry, extensions,
behavior, and authenticated accounts can still link sessions. NeAntik should
present consistency checks as future privacy controls and must not promise that
any third-party service cannot correlate a user.

When a proxy is active, NeAntik currently applies Chromium's proxy leak
controls:

```text
--force-webrtc-ip-handling-policy=disable_non_proxied_udp
--disable-quic
--dns-prefetch-disable
--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE <proxy host>
--proxy-bypass-list=<-loopback>
```

The resolver rule permits DNS resolution of the proxy itself while preventing
other browser components from resolving target hosts directly.

Direct Chromium supports authenticated HTTP/HTTPS proxies through its native
authentication flow. Chromium does not implement SOCKS5 authentication, so
NeAntik Direct accepts SOCKS5 only without credentials.

After a successful proxy test, NeAntik also stores the exit timezone and
primary locale with the profile identity. A compatible runtime receives both
supported Chromium dialects:

```text
--fingerprint-timezone=<IANA timezone>
--timezone=<IANA timezone>
--fingerprint-locale=<locale>
--lang=<locale>
--accept-lang=<locale>
```

Unknown switches are ignored by Chromium. Sending the same value in both
dialects lets NeAntik support Cloak-style and fingerprint-chromium-style
runtimes without injecting page scripts.

## Built-in verification

The Direct app includes **Fingerprint Check** when:

- at least two profiles exist;
- both profiles are stopped;
- the selected runtime passed preflight; and
- the runtime flavor declares fingerprint support.

The check performs three short launches:

1. profile A;
2. profile B;
3. profile A again.

NeAntik connects to a random loopback-only Chromium DevTools port and evaluates
the probe in `about:blank`. It never injects the probe into normal browsing and
does not send results to an external service. Each pass uses disposable browser
data, so the check does not modify the profile's real cookies or sessions. If a
profile has a proxy, its proxy and WebRTC leak-control flags remain active
during the check.

Critical values:

- Canvas pixels;
- WebGL rendered pixels;
- OfflineAudioContext output;
- ClientRects geometry.

Context values:

- WebGL vendor, renderer, and extensions;
- user agent, platform, Client Hints, fonts, screen, CPU, memory, and touch;
- language and timezone;
- a hash and count of local WebRTC candidates, without persisting raw
  candidates.

Verdicts:

- **Distinct and stable**: at least two critical values differ across profiles
  and the repeated profile is stable.
- **Partially distinct**: exactly one critical value differs and remains stable.
- **No critical difference**: the runtime accepted the launch but exposed the
  same critical fingerprint.
- **Identity is unstable**: a critical value changed on the repeated launch of
  the same profile.

Reports are stored locally with owner-only file permissions:

```text
~/Library/Application Support/NeAntik/FingerprintAudits/
```

## Production qualification

The ordinary `verified` verdict is useful for engineering diagnostics, but it
is not sufficient by itself for a production release. A report is
production-qualified only when all of the following are true:

- it was captured in normal browser mode, not a headless diagnostic;
- the ordinary verdict is `verified`;
- Canvas, WebGL pixels, Audio, ClientRects, WebGL vendor/renderer/extensions,
  UA, Client Hints, platform, screen, CPU, memory, touch points, fonts,
  languages, and timezone are available in all three captures;
- all of those required values are stable between the first and repeated
  launch of profile A;
- WebGL pixels differ between profiles A and B.
- the runtime version and valid code signature are recorded;
- SHA-256 hashes bind both the runtime executable and Chromium Framework.

The Direct UI shows production evidence separately from the diagnostic
verdict. The runtime audit CLI enforces the same distinction: diagnostic mode
may prove that the fingerprint protocol works, while browser mode must also
pass the production qualification gate.

NeAntik re-inspects the signature, version, architecture, and both binary
hashes before and after A -> B -> A. If the runtime changes during the check,
the audit aborts instead of saving ambiguous evidence.

After a normal user-session GUI run, prepare release evidence with:

```bash
scripts/prepare-gui-fingerprint-release-evidence.py \
  --source /absolute/path/to/fingerprint-audit.json
scripts/prepare-gui-fingerprint-release-evidence.py \
  --source /absolute/path/to/fingerprint-audit.json \
  --collect
scripts/verify-gui-fingerprint-report.py \
  dist/fingerprint-audit.json \
  --runtime-lock runtime/fingerprint-chromium.lock.json
```

The first command explains whether the report qualifies and why. The second
copies it into `dist/fingerprint-audit.json` only when the independent GUI
verifier passes. The final verifier command additionally binds the report to
the pinned runtime verification report through `runtime/fingerprint-chromium.lock.json`.

## Headless engineering diagnostic

The developer CLI also supports an explicit source-built `headless_shell`
diagnostic:

```sh
scripts/run-runtime-audit.sh \
  /absolute/path/to/headless_shell \
  /absolute/path/to/fingerprint-audit.json \
  --headless-single-process-diagnostic
```

This mode is restricted to an executable named `headless_shell`, records
`headless-single-process-diagnostic` in the JSON report, and prints a
`DIAGNOSTIC ONLY` warning. It adds `--single-process --no-sandbox` because the
current Codex process coalition cannot run Chromium's normal macOS
multiprocess rendezvous. The GUI and ordinary CLI modes remain unchanged and
do not receive those arguments.

Four independent real Blink runs passed with stable, distinct Canvas, Audio,
and ClientRects values, including two runs from the rebuilt Metal target.
WebGL remained unavailable in headless mode, so these reports are explicitly
not production-qualified and do not replace the production Metal GUI gate.
See `docs/FINGERPRINT_DIAGNOSTIC_EVIDENCE.md`.
