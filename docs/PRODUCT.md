# NeAntik 0.3 product contract

## Outcome

A user can create a named profile, optionally assign a proxy, launch Chromium,
sign in to a website, close the browser, and later return to the same session.
Profiles must not share cookies or local storage. When a compatible patched
runtime is selected, every profile must also retain a stable distinct browser
identity.

## Included

- Apple Silicon only.
- macOS 14+.
- Native SwiftUI interface.
- Installed or manually selected Chromium runtime.
- Local profile metadata and browser data.
- HTTP and HTTPS proxy settings; unauthenticated SOCKS5 in Direct.
- Proxy verification through `curl` with credentials supplied over stdin.
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
- One-time repair of legacy seeds outside the runtime's positive signed-32-bit
  input range.
- Capability-aware launch of a compatible external Chromium runtime.
- A local three-pass fingerprint audit that compares two profiles and repeats
  the first profile to detect instability.

## Explicitly excluded

- Intel Macs.
- Electron, Tauri, Node.js, or a web UI.
- Cloud accounts and team sync.
- Browser automation and RPA.
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
- The main screen exposes create, edit, start, stop, reveal, and delete.
- Proxy credentials are absent from `profiles.json` and process arguments.
- Foreground profile reconciliation does not perform the process-table or
  full argument-buffer scan on the main thread. A stale or cancelled
  inventory generation cannot unlock a profile. Lease identity and a
  starting manager's liveness are observed before and after the inventory;
  unavailable anchors stop in a visible fail-closed state instead of polling.
- Stock Chrome never receives fingerprint flags.
- A compatible runtime receives a stable seed and macOS platform identity.
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

- User confirms the native UX direction and whether a bundled Chromium runtime
  should replace installed Chrome after the local MVP.

## Distribution

This is the full product described above. It can launch a separately installed
compatible Chromium runtime and therefore can support different browser-visible
fingerprints. Public builds use Developer ID and notarization.
