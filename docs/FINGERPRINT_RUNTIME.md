# Fingerprint runtime contract

NeAntik itself is a native profile and process manager. Browser-visible
fingerprint values are implemented by a compatible Chromium runtime, not by
JavaScript injected into pages.

## Private launch protocol

A compatible runtime must support:

```text
NEANTIK_PROFILE_SEED=<positive signed-32-bit-compatible seed>
```

NeAntik persists one stable seed in `1...2147483647` per profile. It does not
rotate that seed between launches, because a returning session with a
constantly changing device identity is internally inconsistent.

Only newly created profiles use issuance policy version `2`. The system CSPRNG
selects uniformly between four reviewed Apple Silicon tuple residues and then
uniformly between the `195225786` valid seeds in that residue. The resulting
space contains `780903144` candidates (about 29.54 bits), rather than a small
public seed dictionary. The canonical cross-language contract is
`runtime/browser-identity-issuance.json`.

The four tuples are a conservative reviewed product policy, not evidence that
they represent current market share. A stable seed is not anonymous: it makes
one profile repeatable and therefore linkable between visits. The policy does
not hide NeAntik-specific runtime behavior or guarantee a populated anonymity
set. Issuance v2 reduces the hardware tuple set only: the 780,903,144 full seed
values still make Canvas, Audio, WebGL and ClientRects effectively distinct at
public-alpha population sizes. Shared full-fingerprint cohorts remain a
separate production design problem.

The current owned runtime parses this private environment value as an unsigned
integer constrained to Chromium's signed `int` range. NeAntik therefore never
generates a high-bit `UInt32` seed. The value is absent from process argv and
the manager builds the child environment from a strict system allowlist, so
shell proxy variables, TLS key-log paths, cloud tokens and stale NeAntik
values cannot leak into Chromium. Profiles written by older builds are
repaired once on load:
high-bit values are folded into the supported positive range and any resulting
collisions are resolved before the repaired metadata is persisted. The launch
builder applies the same conversion defensively. Collision repair walks the
same catalog residue, so it cannot silently rotate the profile to another
apparent hardware tuple.

Each profile also persists identity catalog version `1` and the tuple ID
derived from its runtime-compatible seed. Catalog v1 is immutable: its tuple
order and count must not change. An unknown catalog version or a stored tuple
that no longer matches the seed fails closed instead of silently rotating the
profile fingerprint. A future catalog requires a new version and an explicit
user-visible migration.

Identity issuance has a separate version. Missing `issuanceVersion` is always
legacy version `1`; it is never interpreted as the newest policy. Existing,
imported and deterministic migration identities remain version `1`. Unknown
versions and version-2 seeds outside the four reviewed residues fail closed.
Editing proxy settings preserves the original issuance version, seed and
tuple.

Opening version-2 metadata in an older manager can drop the unknown
`issuanceVersion` field on a later edit. The seed and tuple stay unchanged, but
the next current manager will conservatively treat that profile as legacy
version 1. It must not infer issuance provenance from seed membership alone.

Profile metadata writes are atomic and keep one owner-only previous revision.
If the current JSON becomes undecodable, NeAntik restores the valid previous
revision, preserves the rejected bytes under the owner-only `Recovery`
directory, and leaves the profile's `BrowserData` untouched. If no valid
revision exists, storage remains fail-closed.

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

- Receives the persistent profile seed through the private child-process
  environment contract. The runtime is ARM64-only and its macOS platform is
  fixed by the signed build rather than supplied by a mutable launch flag.
- The runtime, not NeAntik, is responsible for coherent Canvas, Audio, WebGL,
  font, ClientRects, WebRTC, language, timezone, and Client Hints behavior.

## Selection

NeAntik Direct uses only the `NeAntik Browser.app` embedded in the signed
application resources. The runtime must declare bundle identifier
`app.neantik.runtime` and flavor `fingerprint-chromium`; otherwise startup
fails closed. There is no external-runtime picker, persisted custom path or
fallback to an installed Chrome, Chromium or Cloak build.

Run **Fingerprint Check** before treating the embedded binary as verified.
Release evidence remains bound to the exact signed candidate rather than a
mutable path or a separately installed browser.

## Privacy boundary

A distinct seed is necessary but not sufficient for anonymity. Proxy exit
location, DNS, WebRTC, timezone, language, screen geometry, extensions,
behavior, and authenticated accounts can still link sessions. NeAntik should
present consistency checks as future privacy controls and must not promise that
any third-party service cannot correlate a user.

Proxy-derived timezone and locale values are applied only when a proxy is
still configured and the local `ipapi.co` evidence is valid and no older than
30 days. Clock skew up to five minutes is tolerated. The ordinary UI launch
path has a stricter route gate: every Start for a proxied profile makes a fresh
observation. It must be bound to the current profile revision, describe the
exact same observation as the saved identity context, contain an observed
exit plus timezone and locale, be no older than 30 seconds and not have been
consumed by a previous browser session. A separate manual health check is
never reused as launch authority.

If that launch gate is not met, pressing Start automatically runs the existing
bounded `curl` probe through the configured proxy, using credentials from the
Keychain over stdin. NeAntik persists the measured timezone/locale, re-reads
the newest profile revision and revalidates the complete evidence pair before
starting Chromium. A one-use short-lived receipt binds that exact revision,
proxy and observation at the process-manager boundary, so a future API/MCP/SDK adapter
cannot bypass the preparation gate. A failed or incomplete probe blocks launch instead of
falling back to Direct or to the Mac's timezone. Direct profiles still make no
location-service request and send no timezone or locale override. Manual and
bulk checks remain available for explicit diagnostics.

When a proxy is active, NeAntik currently applies Chromium's proxy leak
controls:

```text
--webrtc-ip-handling-policy=disable_non_proxied_udp
--disable-quic
--disable-features=AsyncDns,DnsOverHttpsUpgrade[,WebGPUService]
--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE <proxy host>
--proxy-bypass-list=<-loopback>
```

The resolver rule permits DNS resolution of the proxy itself while preventing
other browser components from resolving target hosts directly. Async DNS and
automatic DoH upgrade are disabled in proxy mode as defense in depth. Direct profiles explicitly
pass `--no-proxy-server`, so they do not inherit a macOS HTTP proxy, PAC file,
or proxy auto-detection setting. That switch does not bypass a VPN, Network
Extension, system routing, DNS interception, or an upstream network proxy.
Mandatory Chromium proxy policy and a proxy-controlling extension can also
take precedence over command-line proxy preferences. The current audit records
the configured route; it does not independently observe the effective HTTP
route, so a Direct label is not proof against those overrides.
Direct profiles also use
`--webrtc-ip-handling-policy=default_public_interface_only` to avoid
exposing every local interface while preserving ordinary WebRTC calls.

Direct Chromium supports authenticated HTTP/HTTPS proxies through its native
authentication prompt. NeAntik does not silently inject credentials: the
profile card exposes explicit login/password copy actions. Copied values carry
the macOS transient/concealed pasteboard hints and an unchanged clipboard is
cleared after 60 seconds, but another app can still read a copied value during
that interval. The proxy connectivity test uses the Keychain password, but
does not prove that credentials were entered into Chromium. Chromium does not
implement SOCKS5 authentication, so NeAntik Direct accepts SOCKS5 only without
credentials.

After a successful proxy test, NeAntik also stores the exit timezone and
primary locale with the profile identity. A compatible runtime receives the
validated timezone through the same private environment contract and the
locale through ordinary Chromium language switches:

```text
NEANTIK_PROFILE_TIMEZONE=<IANA timezone>
--lang=<locale>
--accept-lang=<locale>
```

Timezone is intentionally transported only through NeAntik's private
environment contract. Chromium 151 does not expose a supported
`--timezone` command-line switch, so the manager never emits that no-op
argument.

The custom `--fingerprint*` argv family is intentionally unsupported and the
release verifier rejects those legacy NUL-terminated markers in the packaged
runtime. NeAntik supports only its exact embedded runtime contract; it does not
silently claim compatibility with unrelated Cloak-style or
fingerprint-chromium-style binaries.

## Built-in verification

The Direct app includes **Fingerprint Check** when:

- at least two profiles exist;
- both profiles are stopped;
- the selected runtime passed preflight; and
- the runtime flavor declares fingerprint support.

The check performs four short launches:

1. a disposable direct WebRTC positive control;
2. profile A;
3. profile B;
4. profile A again.

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
- the declared direct/proxied route and aggregate WebRTC candidate-type
  counts. Candidate strings, addresses, hostnames, and hashes derived from
  them are never stored.

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
is not sufficient by itself for a production release. Schema 5 deliberately
separates two levels:

- **public-alpha-qualified** proves that the normal browser surfaces used by
  the current alpha are available and stable in A -> B -> A;
- **production-qualified** additionally proves repeat-call and main-realm /
  worker coherence. A legacy schema 1 report may remain valid public-alpha
  evidence, but can never satisfy the strict production gate.

A schema 7 report is production-qualified only when all of the following are
true:

- it was captured in normal browser mode, not a headless diagnostic;
- the ordinary verdict is `verified`;
- Canvas, WebGL pixels, Audio, ClientRects, WebGL vendor/renderer/extensions,
  UA, Client Hints, platform, screen, CPU, memory, touch points, fonts,
  languages, and timezone are available in all three captures;
- all of those required values are stable between the first and repeated
  launch of profile A;
- WebGL pixels differ between profiles A and B.
- repeated Canvas, OfflineAudio, WebGL pixel, and ClientRects reads match the
  first read in each capture, so per-call random noise cannot pass;
- Canvas and WebGL results from the main realm agree with a dedicated Web
  Worker using OffscreenCanvas;
- main-realm and worker UA, Client Hints, platform, languages, timezone,
  `Intl` locale, CPU count, device memory, WebGL metadata/extensions, and
  shader precision agree;
- the primary `navigator.languages` token agrees with the `Intl` locale in
  both the page and worker after `Intl.Locale(...).maximize()` supplies
  likely script and region subtags; variants and Unicode extensions are
  intentionally excluded from this comparison core;
- CSS `device-width`, `device-height`, and `resolution` media queries agree
  with the exposed screen and DPR values;
- the same-run direct `loopback-stun-v1` control completes and Chromium sends
  at least one valid STUN Binding Request to the private loopback responder;
- the configured route declaration and `loopback-stun-v1` WebRTC control are
  valid,
  ICE gathering reaches `complete`, candidate counts are bounded and
  internally consistent, unknown candidate types are absent, and a proxied
  route sends zero STUN requests and exposes no host, server-reflexive, or
  peer-reflexive candidate;
- the runtime version and valid code signature are recorded;
- SHA-256 hashes bind both the runtime executable and Chromium Framework.

The WebRTC probe uses a self-tested UDP responder bound only to
`127.0.0.1` on a random port. It accepts only bounded RFC 8489 Binding
Requests, stores only a saturated request count, and never records packet
bytes, transaction IDs, candidate strings, addresses, hostnames, or endpoint
hashes. The exact audit-only HTTP loopback bypass does not change normal
browsing policy. This mechanism is implemented in source, but must still pass
the fresh signed GUI A → B → A release run before NeAntik claims the shipped
binary has qualified proxy WebRTC protection.

`productionQualified` means strict fingerprint coherence plus WebRTC
leak-control for the configured route. It does not mean that Chromium's
effective HTTP or DNS egress was observed. The verifier therefore emits
`networkEvidenceScope=configured-route-webrtc-only` and
`effectiveHTTPRouteObserved=false`; the UI shows the same limitation.

The Direct UI shows public-alpha evidence separately from strict production
evidence and the ordinary diagnostic verdict. The runtime audit CLI and the
independent Python verifier enforce the same distinction. Missing worker,
OffscreenCanvas, CSS media-query, or shader-precision evidence is a confirmed
strict-production limitation; the gates must not synthesize or substitute
values to obtain a pass.

NeAntik re-inspects the signature, version, architecture, and both binary
hashes before and after A -> B -> A. If the runtime changes during the check,
the audit aborts instead of saving ambiguous evidence.

For a Direct candidate, launch the exact signed manager with canonical
manifest/output paths and then collect only its authenticated schema-8 output:

```bash
open -n /absolute/path/to/NeAntik.app --args \
  --neantik-release-fingerprint-audit \
  --candidate-manifest /absolute/path/to/direct-candidate-manifest.json \
  --output /absolute/private/path/to/fingerprint-evidence-schema8.json
scripts/collect-gui-fingerprint-evidence.py \
  --source /absolute/private/path/to/fingerprint-evidence-schema8.json \
  --integrated-app /absolute/path/to/NeAntik.app \
  --candidate-manifest /absolute/path/to/direct-candidate-manifest.json \
  --output dist/fingerprint-audit.json \
  --summary-output dist/fingerprint-audit-summary.json
```

Raw schema-7 reports saved under Application Support or produced by the runtime
audit kit remain private diagnostics and are rejected by release tooling.

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
