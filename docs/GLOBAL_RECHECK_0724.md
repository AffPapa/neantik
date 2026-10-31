# Full release recheck — 0.7.24 / 87

## Historical manager recheck before the M156 release

The paragraphs below describe the pre-M156 checkpoint, not current publication. Release0.7.24/87 was subsequently published as public alpha with Chromium156.0.8078.12 after its Direct gates; see releases/v0.7.24.json. Major1.0 remains open.

### Pre-M156 publication status

0.7.24/build87 is a verified manager source/Dev candidate, not a published or notarized release. Release preflight stopped first on yesterday's pinned security check date. A fresh independent official check confirms macOS Stable155.0.8059.39/.40, announced October6, above the existing M154.98. The current baseline verifier rejects that runtime. No contract, runtime, threshold or gate was changed; no new ZIP/DMG exists. Public0.7.23 is retained immutable; its older runtime is disclosed on the Site.

Primary source: https://chromereleases.googleblog.com/2026/10/stable-channel-update-for-desktop_086471744.html

## Fixed, reproduced on synthetic fixtures

- Organization corruption/symlink after background refresh incorrectly disabled independently trusted profile metadata. Separate read results preserve last-good folder state and block folder mutations while ordinary profile writes remain available.
- Contended metadata flock parked synchronous UI/MCP entry points until a foreign holder released it. Acquisition now uses LOCK_NB with a monotonic50ms bound; short journal transactions can finish, long contention returns a localized busy failure. Refresh preserves trust on contention; MCP emits storage_busy, no automatic retry. Other process/snapshot guard policies are unchanged.
- IP-service error:true with complete context was accepted. It is rejected without surfacing untrusted body text.
- Malformed first IP response could be overridden by a later service429 and legacy fallback. Each successful service body is now validated before requesting the next one; malformed/contradictory evidence cannot become success. Network route and service availability remain different claims.
- History scanner silently skipped blobs >4MiB. Streaming scanning examines all reachable blob bytes, with cross-chunk recognition and no secret values in output.
- Eight non-live Swift suites were missing from CI. Matrix and suite runner now agree; manager build/test helpers bound jobs2 using the supported native build system. Notices regression selects the current M154.98 contract, rather than an M152 document. Runtime contract/payload unchanged.
- A real740px Help screenshot reproduced the vertically compressed access label. Moving its label above the segmented control preserves readable layout. A helper relaunch without environment opened old Dev QA data instead of the intended3record fixture; --fixture now pins a validated temporary root in the Dev bundle. Production ignores this hook.
- MCP Help distinguishes6read tools from17management tools. Site cookbook explains actual workspace/data-root and uses the standard production-directory example; a different root is a separate workspace.

## Fresh checks and limits

Final integration evidence:743 Swift tests /84suites,830 Python tests with1explicit skip. Synthetic real Dev stdio validates17tools/3prompts,29success output-schema payloads, legacy/modern protocol, read-only denial, revision conflicts, cancellation/EOF and one Chromium start/graceful stop. Held-lock subprocess returned a bounded error in0.116s including process startup, then recovered after release; EOF0.0015s.

Existing M154.98 synthetic runtime: persistent cookies/localStorage/IndexedDB survive ordinary close and controlled crash; session cookies expire after browser restart (not promised restored). Local HTTP fixture confirms Chromium uses proxy; stopping proxy yields ERR_PROXY_CONNECTION_FAILED. A new manager object observes the running browser; literal cross-process reconnect is qualified separately by signed stdio fixtures.

Metadata-only Dev debug benchmark, same executable/conditions,10warm samples/p95nearest-rank: query100profiles1.24ms,1000profiles8.71ms,5000profiles34.61ms p95. Baseline is list-page/client-filter in this candidate, not an older release. No browser fleet launched.

Native GUI provider returned Help accessibility tree, then disconnected on action and screenshot. OS window captures independently confirm the repaired740px Help layout and three synthetic profiles after a relaunch without environment; no data-format alert was visible. Physical chooser keyboard/copy remains unqualified until tool recovery. No system VoiceOver or third-party AI account/model smoke claimed. Public notarization/hosted-byte gates and final URLs are recorded separately after publication.

Secret evidence: recognized formats in full reachable Git history, actual public bundle privacy and exact private-proxy canaries; unknown secret formats cannot be universally disproved. No real profile writes, no new telemetry/cloud, no Chromium rebuild.

## Deferred hypotheses

- Foreground GUI lifecycle refresh following an external MCP launch needs a physical two-process smoke; no wrong-process signaling was confirmed.
- Shared metadata import crash between document commits needs durable multi-document journal research; existing exception rollback tests pass.
- Clipboard cleanup when main window disappears before exit needs native lifetime verification.
- All-device/macOS/client-account compatibility is not certified by one local Mac.

Rollback: immutable0.7.23/build86 and Sites118 retained. Affpapa uses only restricted client; unavailable credential is a channel blocker, not permission to use raw server access.
