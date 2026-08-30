# NeAntik 0.3 product contract

## Outcome

A user can create a named profile, optionally assign a proxy, launch Chromium,
sign in to a website, close the browser, and later return to the same session.
Profiles must not share cookies or local storage. When a compatible patched
runtime is selected, every profile must also retain a stable distinct browser
identity.

On an empty workspace, the primary action creates and opens one permanent
local profile with a stable identity. It states that the initial route is
Direct before the click; the full editor remains a secondary action.

## Included

- Apple Silicon only.
- macOS 14+.
- Native SwiftUI interface.
- One main macOS window. Menu-bar, toolbar and context-menu profile commands
  share one focused command state and become unavailable during modal work.
- Bundled compatible ARM64 NeAntik Browser runtime. The Direct UI neither
  selects nor falls back to an installed external Chromium runtime.
- Local profile metadata and browser data.
- One-level local folders stored in a versioned sidecar so older NeAntik
  builds can still read and rewrite the unchanged legacy `profiles.json`.
- Search across profile names, optional local plaintext notes, tags and
  folders; pinning, archiving and settings-only cloning. Clones never share
  UUID, BrowserData or fingerprint identity and always start with an empty
  note.
- Notes use progressive disclosure: the full editor row opens a multiline
  plaintext field, the selected profile reveals its text in the detail pane,
  and compact profile rows show one normalized, truncated plaintext line.
  Notes remain ordinary local profile metadata: no rich text, cloud sync or
  Keychain storage. The editor warns not to store passwords, API keys or seed
  phrases there.
- Tags keep their text label and receive a stable dynamic system-color marker
  as a secondary visual cue; status red, orange and green remain reserved.
- Move-to-folder menus stay bounded to eight useful choices. Larger
  workspaces continue in a searchable native folder picker, with the current
  folder always kept in the quick list.
- One-click first-profile bootstrap that persists before launch and leaves the
  profile available when runtime launch fails.
- HTTP and HTTPS proxy settings; unauthenticated SOCKS5 in Direct.
- Proxy verification through `curl` with credentials supplied over stdin.
- Explicit single and bounded three-at-a-time bulk proxy health checks with a
  timestamp, response time and sanitized outcome. Persisted health never
  includes the exact observed IP or credentials.
- Automatic fresh launch preparation before every proxy-bound browser
  session. A manual health check remains informative but is never reused as
  launch authority. Start uses the same bounded probe, persists a coherent
  timezone/locale and launches only with a one-use, short-lived,
  revision-bound receipt. Direct profiles never invoke this external probe,
  and failure never silently falls back to a direct route or host timezone.
- Keychain password storage.
- Crash-safe profile locks and local logs.
- A bounded same-user process inventory captured outside the UI actor. One
  foreground reconciliation or passive recovery tick reads each process at
  most once; foreground and passive captures are globally serialized. It
  retains only the kernel executable path, process birth identity and absolute
  profile-data paths, securely scrubs the raw argv/environment buffer with
  `memset_s`, keeps inaccessible state fail-closed, and never persists or logs
  process arguments.
- Persistent per-profile fingerprint seed.
- New-profile identity issuance version 2 uses the system CSPRNG across
  780,903,144 positive signed-32-bit seeds in four reviewed Apple Silicon
  cohorts. Missing issuance metadata remains legacy version 1; existing,
  imported and migrated profiles never rotate automatically unless a legacy
  high-bit value or local collision requires one-time repair.
- One-time repair of legacy seeds outside the runtime's positive signed-32-bit
  input range. Collision repair preserves the existing device-tuple residue
  instead of silently changing the apparent hardware cohort.
- The four-cohort policy narrows hardware tuples but does not yet create shared
  full-fingerprint cohorts; strict production entropy reduction remains open.
- Capability-aware launch of the bundled compatible Chromium runtime.
- A local three-pass fingerprint audit that compares two profiles and repeats
  the first profile to detect instability.
- A user-facing environment inspector that distinguishes configured, derived,
  observed, unavailable and unverified claims for route, fingerprint, WebRTC,
  QUIC/DNS and proxy-derived geolocation.
- A paste-first bulk proxy profile flow with local per-line preview, complete
  line-numbered validation, progressive disclosure for secondary settings and
  atomic persistence. Pasting never performs a network request.
- Environment readiness groups duplicate symptoms by root cause. Optional
  fingerprint/WebRTC audits remain neutral until run; launch-fixable proxy
  context is described as automatic, while observed failures expose one
  relevant action.
- One immutable workspace projection and an allowlisted read-only DTO for the
  native UI and future local API/MCP/SDK adapters. There is no listener or
  write API in this version.

## Explicitly excluded

- Intel Macs.
- Electron, Tauri, Node.js, or a web UI.
- Cloud accounts and team sync.
- Browser automation and RPA.
- Network-accessible, automatically enabled or unauthenticated APIs.
- API/MCP/SDK methods that launch browsers or mutate/delete profiles.
- Mobile emulation.
- Claims of being undetectable or anonymous against every service.
- JavaScript-based fingerprint injection.
- Prediction of whether a third-party service will accept an account.

## Definition of done

### Programmatic

- `swift test` passes.
- `swift build -c release --arch arm64` passes.
- `scripts/package-app.sh` produces a valid arm64 `.app`.
- `codesign --verify --deep --strict dist/NeAntik.app` passes.

### Judge

- The profile creation form has no nonessential settings.
- The creation order is name, visible optional note and optional proxy;
  folders, tags, start URL and appearance stay under one additional-settings
  disclosure.
- The empty workspace exposes `Create and open`, states `Direct connection`
  before launch, and keeps `Configure...` as the secondary path.
- The main screen exposes create, edit, start, stop, reveal, and delete.
- An optional note can be opened by clicking the whole editor row, accepts
  multiline plaintext, is readable from the selected profile, searchable and
  represented by a normalized one-line preview in the compact profile row. A
  clone has no note.
- Every profile row exposes state and route as text plus a symbol and keeps a
  labelled launch/stop action visible without relying on color alone.
- Proxy credentials are absent from `profiles.json` and process arguments.
- Foreground profile reconciliation does not perform the process-table or
  full argument-buffer scan on the main thread. A stale or cancelled
  inventory generation cannot unlock a profile. Lease identity and a
  starting manager's liveness are observed before and after the inventory;
  unavailable anchors stop in a visible fail-closed state instead of polling.
- Stock Chrome never receives fingerprint flags.
- A compatible runtime receives a stable seed and macOS platform identity.
- Proxy-derived timezone and locale overrides are sent only while their
  explicit local evidence is fresh; stale, missing and direct-profile context
  is omitted rather than asserted.
- The fingerprint audit distinguishes verified, partial, unchanged, and
  unstable runtime behavior from measured browser output.
- A production-qualified fingerprint report must come from normal browser
  mode, make every critical surface plus WebGL vendor/renderer available and
  stable, and prove different WebGL pixels between profiles.
- Production evidence must bind the exact runtime executable and Chromium
  Framework SHA-256 values and reject a runtime changed during A -> B -> A.
- Headless diagnostic mode can verify protocol behavior but can never satisfy
  the production release gate.
- The app remains useful without a server or NeAntik account.

### Human

- User confirms the native one-window workflow with the bundled Direct runtime.

## Distribution

This is the full product described above. Direct builds launch their bundled,
compatible NeAntik Browser runtime and never silently fall back to an installed
browser. Public builds use Developer ID and notarization.
