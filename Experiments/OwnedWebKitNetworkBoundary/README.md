# Owned WebKit network boundary — research

This is an independent experiment, **not the shipping WebKit implementation**.
The manager still refuses WebKit proxies. No production profile, default website
data store, system extension, global proxy/DNS setting or Keychain group is used.

**Observed:** seven headed HTTP controls pass on the owned sandboxed runtime.
The intentionally unconfined copy reproduces private-IP Direct with the same
proxy configured. See the [scoped report](../../docs/evidence/webkit-owned-runtime-http-development.json).
This is evidence for the boundary, not a qualified product assembly: strict
framework bundle verification still rejects the development layout's external
XPC service symlinks. Shipping proxy remains disabled.

**Later assembly slice:** the original research layout remains frozen. A new
standalone ARM64 copy materializes nested XPC code, relinks dependencies and
passes strict/deep Developer ID verification with hardened runtime. Its two
headed baseline controls and eight restricted HTTP controls pass, including
an intentional configured-proxy Direct bypass control. The own Networking
helper's exact file is independently observed. See the
[standalone report](../../docs/evidence/webkit-standalone-bundle-development.json).
It is not notarized or shipping-qualified; protocol and integration gates below
remain open.

**TLS development slice:** `TLSHost.m` adds an ephemeral, process-only QA root
with real chain/signature/hostname checking, without Keychain/system trust edits.
`tls_fixture.py` tunnels actual TLS bytes through authenticated CONNECT to an
owned origin. Six real wire and seven acceptance/negative controls pass. Two
native matrices retain FAIL for diagnosed request-versus-connection assumptions;
their five confirmed conditions are preserved. The final remaining/setup phase
passes six controls, including wrong CA, relay refusal/recovery, independent
Direct and intentional unconfined HTTPS bypass. The
[TLS report](../../docs/evidence/webkit-owned-tls-development.json) separates
these phases; it is not a single final-candidate matrix. Temporary keys and
owned hosts/helpers/sockets are cleaned up. DNS/UDP and product gates remain.

### Assembly tools

- `assemble_layout.py` creates a new clone, rejects unexpected/escaping links,
  materializes eight known nested-code links, completes the known empty WebCore
  Frameworks alias, and omits unused SDK stubs. Existing outputs are refused.
- `stage_bundle.py` stages an ARM64-only QA app with rewritten Mach-O paths;
  non-code shader resources live in Resources. It does not launch or sign.
- `sign_bundle.py` describes inside-out QA signing, including nested JSC helper
  executables. It is a QA helper, without release timestamp/notarization gates.
- `bundle_probe.py` tests the changed packaging. Rpath-only packaging loaded
  system and owned WebKit together; retained launchd evidence identifies XPC
  service-name collisions. Fixed own framework paths use upstream WebKit's
  loader convention and the narrow Host `allow-dyld-environment-variables`
  entitlement. Inherited loader paths are removed; library validation stays on.
- `confined_bundle_probe.py` freezes a separate restricted QA identity and a
  fixed loopback port, verifies the Developer ID team recursively, then runs
  eight controls and checks helper-file mappings and cleanup. It refuses a
  previous result. This fixed QA listener is not a multi-profile product broker.

Tests cover fixture authentication/draining, filesystem escape/refusal and
environment sanitization. A diagnosed Darwin accept wake-up failure is retained;
the fixture now calls shutdown before close and joins all owned threads.

## Why a different runtime

System WKWebView's proxy configuration admitted private-IP Direct traffic in
the retained native tests. The official development WebKit archive includes
its own Networking XPC service and a runtime sandbox resource. That gives us a
concrete place to restrict outbound traffic before page requests execute.

Archive: official Tahoe universal release `324120@main`, SHA-256
`16a396caaa98c9562b22b7de09ca6a9df3ed410de4828976b0711e3ea4bf9728`.
The downloaded ZIP was checked for path traversal, special entries, symlink
escapes and CRC failures before extraction. This hash records downloaded bytes;
it is not an upstream signature or notarization claim. Upstream development
signatures are ad hoc. The archive's minimum macOS version is **26.5**, so it
cannot be substituted into our currently supported release without a separate
compatibility solution.

## Implemented experiment

- `Host.m` uses a nonpersistent store, verifies the actual loaded framework
  path, shows a real window and accepts only the fixture's exact URL list.
- Configuration and synthetic proxy credentials arrive over stdin. Output
  contains outcome codes and counters, not URLs, passwords or fingerprint data.
- `probe.py prepare` compiles the small host with the project developer-dir
  resolver and signs its two QA bundles with the existing NeAntik certificate.
  It clones all sibling runtime products into one admitted directory without
  replacing any installed app. External sibling symlinks caused WebCore bundle
  reads to fail after sandbox entry; that failing layout is retained separately.
- Unused `.tbd` SDK stubs are preserved outside the runtime copy before signing.
  They are not signable runtime components. The original archive is retained.
- `run` first requires normal native admission, then appends an outbound deny
  rule to only its private framework copy. Its own relay port is the only IP
  destination allowed; original netsrc routing metadata and syslog remain.
  `localhost` covers loopback address families; this is not an IPv6 proof.
- A and B use the restricted and original framework respectively. The relay
  fixture authenticates CONNECT and serves an owned marker itself; it does not
  prove a real remote proxy, TLS, DNS or Internet route.
- The seven browser controls require Direct B, authenticated named A, no
  private-IP Direct A, upstream refusal, an independent B and recovery. Both
  windows, servers and the exact owned helper executable paths are checked
  during teardown. A missing result or timeout is a failure.
- `diagnose-proxy` is a separate positive control on the unmodified archive.
  It distinguishes proxy API support from sandbox-policy failure.
- `test_probe.py` covers the wire fixture's successful auth, wrong auth,
  foreign destination, refusal and draining. These are not browser evidence.

Native receipts remain under the dated private project checkpoint. Never
overwrite a previous result to report success; preserve the reason and inputs
before a changed-input retry. A policy syntax check uses compile-only API and
does not apply a sandbox to the runner.

## Still required before a product feature

1. Preserve the seven HTTP controls and the intentionally broken control.
   Repeat only for changed runtime/policy/host inputs or a diagnosed failure.
2. Verify DNS/delegated connections, WebRTC/UDP, HTTPS, WebSocket, downloads,
   workers, refusal and lifecycle boundaries on the owned runtime.
3. Choose a stable broker endpoint and per-profile authenticated session
   binding. This QA regenerates and signs a policy for a random port; a shipped
   notarized resource cannot be rewritten for every user/profile.
4. Build a distributable assembly with fixed load paths, hardened runtime,
   preserved source/license notices and corresponding source delivery, then
   Developer ID/notarization/Gatekeeper qualification. The QA host is not that
   release assembly.
5. Provide a supported macOS baseline and integrate the host with manager
   lifecycle, profile storage, window autosave and MCP. The present experiment
   does none of those migrations.

Official upstream references:
[build archives](https://webkit.org/build-archives/),
[license information](https://webkit.org/licensing-webkit/),
[network sandbox source](https://github.com/WebKit/WebKit/blob/d22fe75a1b10a54d034da33bf2174cff9814639b/Source/WebKit/NetworkProcess/mac/com.apple.WebKit.NetworkProcess.sb.in).
