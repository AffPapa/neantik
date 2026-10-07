# NeAntik 0.7.20 (83) — manager candidate

7 October 2026. Published baseline: v0.7.19 (82). Publication is pending.
Qualified Chromium 154.0.8037.98 is unchanged. Direct Distribution only.

## Changes

- Storage rejects unknown schemas before reading their payload and preserves
  newer organization documents instead of replacing them from an older backup.
  Move and metadata Undo fail promptly during a background import.
- Normal launch validates the persisted revision, proxy, identity, archive and
  start page under process → metadata guards. A captured UI value cannot select
  an obsolete route after another window changes the profile.
- Proxy stdin is written after the child starts, off the calling actor. Manual
  tests change health only. After automatic preparation durably saves context,
  its paired health write completes before cancellation prevents browser launch.
  A later health write failure is fail-closed and requires another check; this
  does not promise an atomic transaction across both files.
- Partial proxy observations explain the missing timezone and language without
  claiming launch readiness. The editor compares complete drafts, including
  unparsed proxy paste; reverting an edit removes the unsaved-change flag.
- Interactive AX controls are exposed. System VoiceOver is not enabled.
  Quick commands have a separate Open/Show button and Cmd+Return action;
  ordinary Return selects the profile in the manager.
- Read-only MCP pages have revision-bound cursors, a 64 MiB metadata cap and a
  256 KiB response cap. They expose allowlisted metadata only. Every page still
  reads and hashes the complete file; caching and mutating tools are deferred.
- Qualified ZIP and DMG files get independent read-only upload inodes with exact
  checksums. Original recovery journal hardlinks remain intact. A copy receipt
  is not release qualification: normal signing, notarization and hosted gates
  still apply. FIFO, symlink, oversize, output swap, disk-full and mutation
  during hosted verification fail safely.
- Legacy `about:blank` profiles are readable again; other about/file/javascript
  URLs remain rejected. Read failures are labelled as load failures. Fresh Dev
  fixtures preserve prior data and can contain eight synthetic profiles with a
  folder, tags, pinning, an archive and long names. Dev version and build now
  track manager source instead of inherited runtime packaging metadata.

## Verification

715 Swift tests in 80 suites passed. 45 Python release/UI tests and four input
snapshot tests passed. The actual previous Dev metadata decoded 10 profiles,
including five `about:blank`, with bytes unchanged.

The existing packaged runtime passed ordinary blank-page launch and stop,
synthetic persistent-cookie/localStorage/IndexedDB persistence, reconciliation
by a second manager instance, clean close, controlled browser crash and relaunch.
Session cookies expire after close under the existing runtime policy. The second
manager instance is not a literal manager process restart.

A local HTTP proxy served a reserved `.invalid` destination. Stopping that proxy
produced `ERR_PROXY_CONNECTION_FAILED`. No external proxy credentials were used.
An early fixture read before loading and requested stop before macOS finished
launching; its assertions failed. That identified synthetic browser required
controlled cleanup after graceful close did not finish. The revised fixture
waited for page and GUI readiness, passed, and closed its browser. Production
browsers were not signalled.

Warm debug search p95 at 1,000 profiles: before 0.743417 ms / after 0.730750 ms.
Quick-command filtering: before 7.224292 ms / after 7.185041 ms. At 5,000 profiles,
after p95 was 3.759417 ms for search and 35.475916 ms for commands. These measure
Swift projections, not full GUI latency.

## Pending gates and limits

Physical editor, quick-command, Tab, Escape, Return and window QA is incomplete:
Codex native UI transport closed. A full AX tree and Cmd+N were observed before
the connection failed; that is a partial pass. Source candidate `528c201` passed
signed runtime audit, Developer ID, notarization, stapling and Gatekeeper. The
later documentation checkpoint adds this release's CHANGELOG section and must
be included in a final source-bound candidate after physical QA. Previously
qualified artifacts are retained; their qualification is not transferred to a
new source commit. Hosted bytes and the public Sites rollout are still required.
No new public download is advertised.

Other Macs and external chat clients are untested. There is no anti-fraud bypass
claim. VoiceOver traversal is untested. Safe Browsing remains disabled. The
restricted affpapa publication credential is unavailable. Previous immutable
v0.7.19 assets remain available for rollback.
