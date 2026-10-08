> Current0.7.24/build87 is an unpublished source/Dev candidate. Fresh official Stable155.0.8059.39/.40 blocks public packaging with unchanged154.0.8037.98; no notarized0.7.24 assets or new download links. Immutable0.7.23 retained. See GLOBAL_RECHECK_0724.md.

# NeAntik Direct source-to-site handoff

## Current bounded recheck0.7.24/87

Storage refresh, bounded metadata contention, IP failure/fallback validation, complete streaming privacy scan, CI coverage and MCP workspace/help clarity. Fresh evidence and deferred hypotheses: [GLOBAL_RECHECK_0724.md](GLOBAL_RECHECK_0724.md). Public release gates recorded separately; qualified Chromium154.0.8037.98 unchanged.

## Current MCP AI slice0.7.23/86

Manager changes modern/legacy interoperability, queries, folder response bounds, errors, prompts and7client onboarding formats. Sites has17toolguide + client selector + prominent AI section preserving traditional profile browser positioning. Qualification/publication evidence: docs/MCP_AI_COVERAGE_0723.md and release manifest/API, not old handoffs.0.7.22/85 and Sites116 retained for rollback. Affpapa doctor still reports unavailable deploy credential; no alternate server route.

## Current manager candidate — 7 October 2026

0.7.22 build 85 on `codex/neantik-mcp-management-0722` expands the local MCP
management contract. Published baseline is v0.7.21/84 until Direct gates and
GitHub/Sites publication complete. Chromium 154.0.8037.98 is unchanged.
This document is source handoff; signed manifests, receipts, immutable assets
and live API establish publication authority.

16 tools cover configuration/organization and session-owned lifecycle; explicit
management mode, locked revisions, canonical Keychain/rollback, shared proxy
observation commit, bounded cancellation and GUI metadata refresh preserve
existing manager policies. Read mode does not repair corrupt primary metadata.
See `MCP_GUIDE.md` and `MCP_MANAGEMENT_0722.md` for exact scope and limits.
Historical sections below are not current runtime or release authority.

## Completed manager release — 3 October 2026

0.7.13 build 76 is published at GitHub and browser.free (Sites version 106).
Exact app-source commit: f2ae87d0adc77c3fb755d144b82f21ac07efaca1.
Developer ID, notarization, stapling, Gatekeeper and fresh hosted ZIP/DMG hashes passed.
API confirms 0.7.13/76, canDownload=true, exact ZIP SHA. /download retains its
existing 307 to /#install; the landing exposes direct ZIP/DMG URLs.
See releases/v0.7.13.json for immutable hashes and limitations.
Chromium remains the qualified 154.0.8037.93 payload; the Integrated source and
previous release runtime have identical inventories (482 files/symlinks).

Implemented: shared quick commands (Cmd-Shift-P), safe user template previews,
saved workspace filters, revision-checked metadata Undo (Cmd-Option-Z), one-at-a-time
launch admission with pressure/thermal backoff, and a bounded typed local journal.
Batch selection/launch UI is deferred; existing individual starts use admission.
Templates exclude identity, BrowserData, notes, proxy credentials and URL tokens.

Confirmed Stop defect: SIGTERM could lose recently buffered persistent-cookie and
localStorage writes. Managed browsers now receive native graceful quit, with exact
executable matching and no forced-kill fallback. Pending/refused quit retains locks.
The existing-runtime localhost fixture passes persistent cookie, localStorage and
IndexedDB after clean close/relaunch and a controlled browser crash. Session cookies
expire after clean close under unchanged Chromium policy. Coordinator reconciliation
was tested in a second instance in the same process; this is not a literal manager
process-restart session test.

Validation: 658 Swift tests passed (76 suites), separate opt-in exact-runtime fixture
passed; GUI Dev.app on synthetic temporary data covered commands, Escape/Return/Tab,
profile creation/edit, launch/stop, template preview/create, filter apply, metadata
Undo and typed journal. No VoiceOver claim. Warm debug search baseline p95 at
100/1000/5000 profiles: 0.104/0.798/4.022 ms; after isolated run at 1000: 0.757 ms,
quick-command filtering 4.187 ms. These measure Swift projections, not end-to-end
GUI latency. Full concurrent test-run timings are retained separately.

G/H: deletion warning now explicitly distinguishes Archive from irreversible
credential cleanup. Recoverable deletion and encrypted BrowserData backup are
deferred with recovery/fault criteria in `MANAGER_RECOVERY_BACKUP_DESIGN.md`.
Metadata snapshots are not session backups. Existing release 0.7.12 remains rollback.
The restricted affpapa deploy credential is still unavailable. GitHub/Sites release
passed the exact candidate's production GUI, signing, notarization and hosted gates.
The first production GUI attempt timed out without evidence. One no-CUA control
generated a valid authenticated production report and drained browser processes;
the manager itself needed the existing wrapper timeout before report verification.
The cause of the first failure remains unresolved; no gate was weakened.

## Completed release — 2 October 2026

NeAntik **0.7.12 build75**, Chromium **154.0.8037.93 / ARM64 / Metal**, is published at GitHub `AffPapa/neantik` and browser.free. Exact app-source commit: `24de0234122ae49257011eef573502b822fcb157`.
Developer ID, notarization, stapling, Gatekeeper, authenticated production GUI A→B→A and fresh hosted ZIP/DMG verification passed. browser.free Sites version99 (`8d9551152d1862db630dbc5ed33ba39279ca8750`) reports canDownload=true and exact ZIP SHA; / and /download expose direct ZIP/DMG links.
See `releases/v0.7.12.json` and `.md` for artifact hashes and limits. Safe Browsing remains disabled. Physical keyboard/VoiceOver traversal is not claimed. Immutable v0.7.11 is the rollback.

No Chromium rebuild is needed to continue from this state. The earlier accepted candidate containing a local Metal toolchain RPATH was never published; its transaction and app are retained privately. Final candidate removes those RPATHs and passed full-bundle privacy checks. The standard hosted ZIP wrapper rejects the publisher's local hard link; fresh single-link downloaded bytes were pinned and passed the same archive, candidate and authenticated evidence gates without changing the public artifact.

GitHub release tag/source branch is published. `main` has divergent history and was not force-pushed. The separate restricted affpapa.org deploy credential remains unavailable; browser.free was deployed through its authorized existing Sites project.

## Historical snapshot — 29 September 2026

Snapshot recorded against the public GitHub Release and browser.free on 29
September 2026. GitHub was freshly checked through the connected API; the
local `gh auth status` check reports invalid stored CLI tokens, so release
upload through that CLI is not currently authorized. The live page and
`/api/release` confirm the Chromium 153 / M154 runtime gate. Sites reports a
successful version 98 deployment from
`827e7231d0a756063425387d4c635d7066fa0424`. GitHub release prose still refers
to Sites version 92. This document does not make newer local manager changes a
public release candidate.

## Public release baseline

- GitHub's latest release is immutable `v0.7.11`, build `74`, bound to source
  commit `fa3b03cbe122840ea308d2ecf19004a1128a1a06`.
- ZIP SHA-256:
  `141ffacec0fb601a9e20fa722b348bc6eed444132efee9c72ab582b5645d3576`.
- DMG SHA-256:
  `fa0489a57b790f51f3d8eea0fa2b4d816bf9a123559f9fd0da71e0ddab6521f4`.
- The live API reports `published-runtime-gated`, `canDownload=false`, and no
  download URL. Chromium `153.0.8010.52` is below the minimum `154.0.8037.58`;
  runtime readiness, strict fingerprint coherence and owner release readiness
  are false. The API ZIP SHA matches GitHub. The live landing page shows the
  same gate and links to `v0.7.11`. GitHub's release prose still refers to
  Sites version 92 while Sites version 98 is active.
- Release `v0.7.10` remains available as the recorded rollback.

### Fresh external gate recheck — 27 September 2026

The public GitHub latest-release endpoint still returns immutable
`v0.7.11` / build 74. Its ZIP digest is unchanged and matches the fresh
`browser.free/api/release` response; the DMG digest also matches GitHub
release metadata. The API explicitly reports `published-runtime-gated`,
`canDownload=false`, and the Chromium 153.0.8010.52 versus 154.0.8037.58
baseline block. The Sites project remains active at version 98 on
`https://browser.free`.

The permitted macOS Keychain check finds four valid signing identities,
including two Developer ID Application identities. The existing
`neantik-notary` Keychain profile is usable and returns 100 history records;
the latest accepted submission is `NeClip-2.8.7.dmg`, so it is not notarization
evidence for an M154 NeAntik candidate. The read-only AffPapa release doctor
still reports that its deploy credential is unavailable at a redacted private
path. That blocks this server publishing client only and does not imply that
GitHub API access is unavailable. No M154 release candidate exists to sign,
notarize, publish, or roll back.

Follow-up connector checks later on 27 September again returned GitHub's
immutable `v0.7.11` release and confirmed Sites version 98, source commit
`827e7231d0a756063425387d4c635d7066fa0424`, with its production deployment in
`succeeded` state. A direct API request without a browser-like User-Agent
returned HTTP 403; a read-only retry with one returned HTTP 200 for both the
landing page and `/api/release`. The fresh JSON still reports the same ZIP
SHA-256, Chromium 153.0.8010.52 below the 154.0.8037.58 baseline, and
`canDownload=false`. The earlier 403 was an edge/request-policy result, not DNS
failure or evidence that GitHub access was unavailable.

## Local manager changes after 0.7.11

Subsequent source work improves off-main-actor profile import and recovery,
snapshot-restore progress, and clearer BrowserData scan-limit status. Tests
cover transaction recovery, entry/byte caps, and fail-closed symlink behavior.
The implementation checkpoints are `66c590b` and `29b4325`; neither is
represented by the 0.7.11 source binding or binary. Pin the final clean Git HEAD
before creating any future exact candidate.
App-issued speech announcements were removed; keyboard actions and native
macOS control metadata remain. The current local HEAD additionally hides the
main SwiftUI accessibility subtree plus sheets and popovers per owner request.
An earlier limited local Dev.app session recorded: `Cmd+N` opened the profile
editor; Tab moved from Name through Folder and Tag to Cancel and Create; Escape
cancelled without saving; `Cmd+Shift+N` opened the folder editor, Tab reached
Cancel, and Escape cancelled; `Cmd+F` focused profile search. The workspace
still showed zero profiles afterward. VoiceOver itself was not launched. This
record is not bound to an exact source hash. A later repeat attempt on
25 September did not reach the UI after a Development-data format warning; the
warning was dismissed without changing or recovering that data. Treat the
earlier check as historical and repeat keyboard smoke on a usable Dev.app and
the exact release candidate. Native macOS menu/titlebar and system-alert
behavior remains OS-controlled. These local changes are not present in the
public 0.7.11 binary or its release evidence.

The retained local candidate is not a package of the current source: its
embedded runtime is `153.0.8010.52`, differs from the repository runtime lock
`152.0.7977.64`, lacks the embedded source contract, and falls below the
minimum security baseline. Do not package or publish it as a newer release.
The current default-shell read-only 13-gate preflight passes 5 and blocks 8:
channel, version/build floor, runtime-lock match, embedded source provenance,
security baseline, GUI channel, and two signing/notary environment values. The
unset shell variables do not prove that Keychain identity or notary profile are
absent. The preflight does not sign, notarize, upload, or approve the retained
app.

## Next Direct release gates

The fresh M154 compatibility experiment is recorded in
`runtime/chromium-154-ungoogled-common-replay.json`: 61/109 pinned M153
common patches applied to official M154 source, 48 failed, and only 6/11
NeAntik runtime groups still pass a context check. This is not a build or
candidate. The replay file actually targets Chromium `154.0.8037.60`; it is a
separate experiment and does not qualify the current Stable `.58` source. First
pin and review the M154 common/macOS packaging port and rebase the failed
patches; keep all current public assets unchanged until the runtime gates pass.

Follow-up execution used the exact official macOS Stable source tag
`154.0.8037.58`, commit `a654841425914cbb703a2931e07b70a83aedbafd`, with pinned
DEPS and hooks in a disposable `/private/tmp` build root. GN generated 35,105
targets. A four-job diagnostic `chrome` compile reached 11,815/14,159 actions,
then failed because patch replay removed `safe_browsing::ThreatDOMDetails`
while M154 still calls it from `chrome_content_renderer_client.cc:670`. An
earlier temporary compile fix restored a blocklist setter but left its request
URL empty; that was only a compile probe and has no runtime or privacy proof.
The product repo still contains no M154 source contract, qualified patchset,
runtime lock, or candidate. An attempted temporary edit to remove the renderer
hook was rejected by automatic review as weakening Safe Browsing; no bypass was
used. The intended NeAntik privacy build setting and security tradeoff now need
an explicit owner decision before this code path is ported. No public artifact
or product source/runtime contract changed by the probe.

A later isolated GN pass retained the shipped `safe_browsing_mode=0` setting.
In the latest disposable M154 tree, exploratory conditional-dependency edits
resolve generation plus `gn check` for `//chrome:chrome`, browser tests, unit
tests, and interactive UI tests; the dependency edits were not reviewed or
copied into product source. A four-job ARM64 `ninja chrome` then stopped at
Crashpad MIG generation because the selected Xcode-beta 27.0 SDK lacks
`usr/include/mach/exc.defs`. The matching Command Line Tools SDK contains that
file, but using it as an override fails GN's input-path constraint. A
subsequent disposable build-output SDK overlay links the three missing
interface files from the matching Command Line Tools 27.0 SDK into the
generated SDK view, without editing Xcode or Chromium build rules. Crashpad MIG
then passed and the mode-0 ARM64 diagnostic build continued. This mixed SDK
view is not a supported/reproducible release toolchain and cannot qualify a
candidate. Later build evidence is recorded below.

The local `dist/fingerprint-audit-summary.json` says `productionQualified=true`
for build 74 / Chromium 153, while `releases/v0.7.11.json` says strict
production fingerprint coherence is `false`; both cite the same candidate
manifest SHA-256. Treat the dist attestation as contradictory, unqualified local
evidence until its producer and qualification rule are reconciled. Do not use it
to qualify the release.

The exact local 0.7.11 ZIP/DMG were rechecked on 26 September: byte sizes and
SHA-256 match GitHub metadata, `hdiutil verify` reports a valid DMG checksum,
and `xcrun stapler validate` accepts the DMG ticket. The contained 0.7.11 build
74 app passes strict `codesign --verify` and macOS Gatekeeper accepts it as
Notarized Developer ID. The app bundle itself has no stapled ticket; the
published DMG ticket validates. This fresh result supersedes the earlier failed
host check for the exact public 0.7.11 package. The current identity and
notary-profile recheck is recorded above; these historical checks of the old
public release do not provide evidence for an M154 candidate.

Local storage audit found about 31 GB under `dist` (including 26 GB of retired
notary package stages), 8.4 GB under private release attempts, and 3.5 GB under
Swift/Xcode build caches. These contain prior app copies and notarization
evidence; nothing was deleted. No tracked `.log` files exist. There are 103 log
files / about 165 KB in the release-attempt and notary-retired trees, and 144
logs / about 265 KB across build/artifact areas; retain until each is matched to
its release-attempt record. A redacted secret scan covered source/docs/runtime
and the 23 September 2026 release-attempt directories (files capped at 1 MB).
Findings were limited to cryptographic key type names and SHA-256-shaped
attestation IDs. It did not fully scan older retained bundles, large binaries,
or all notary-retired packages, so the whole-tree scan is partial.

### M154 compile follow-up — 26 September 2026

Two compile blockers were investigated in the disposable Chromium 154 tree.
Enterprise `ShouldObfuscateDownload()` used a Safe Browsing API absent in
`safe_browsing_mode=0`; simply compiling out the call would remove
block-until-verdict enterprise file obfuscation. The call was replaced in the
disposable tree by equivalent direct `FILE_DOWNLOADED` connector-policy
resolution, retaining file-URL exclusion, Android's enterprise-scan feature
gate, report-only behavior, and the existing download/size preconditions. Its
production object compiled. The mode-0 unit-test translation unit does not
compile because unrelated pre-existing tests in that file reference types
excluded by mode 0; mode-0 runtime behavior is not yet proven.

Further compilation showed that enterprise cloud file scanning itself uses
sandboxed ZIP/RAR analyzers and consumes encryption metadata. M154 mode 0
removes those analyzer Mojo interfaces, wrappers, service binding,
implementation, and result types. An experimental enterprise-cloud-only GN/Mojo
gate in the disposable tree now generates those interfaces and compiles the
`files_request_handler.o` object with `safe_browsing_mode=0`; this is compile
evidence only, not tested archive behavior. The first six-job `chrome` build
reached 52,903/57,607 actions, then stopped before link at
`content_analysis_delegate.cc:965`: `GetBinaryUploadServiceForConnector` was
undeclared because its declaration and implementation remained behind
`SAFE_BROWSING_AVAILABLE`, which is 0 in this mode. Temporary compile-only
guards and enterprise GN wiring then moved the build past that error and
reached framework ThinLTO linking. The first link exposed unresolved
`ArchiveAnalyzerResults` IPC `ParamTraits` plus
`SecurityEventRecorderFactory`, `SafeBrowsingNavigationObserverManagerFactory`,
and `SearchHijackingDetector`. Adding the enterprise-gated traits generation
to `common_message_generator` resolved the IPC symbol. Temporary enterprise-
gated sources and the security-events dependency resolved the security-event,
search-heuristic, and navigation-observer factory symbols. The remaining link
failure was the `SafeBrowsingNavigationObserverManager` implementation,
which upstream GN compiles only when `safe_browsing_mode > 0`. The disposable
tree then included that observer implementation under the enterprise cloud
analysis gate while keeping `SAFE_BROWSING_AVAILABLE=0` and
`SAFE_BROWSING_DOWNLOAD_PROTECTION=0`. Its readiness method requires both the
Safe Browsing preference and service, but the new mode-0 enterprise path still
needs tests proving that navigation, clipboard, IP, and referrer data are not
collected or uploaded when that service is absent. The full `chrome` target
then linked successfully: 483/483 incremental actions, exit 0. The unsigned
app reports `NeAntik Browser 154.0.8037.58`, arm64 executable SHA-256
`8f7e464000a83fa0298ecd3d0cb075c5a4d298fbb1a3f1de8f582a1683775886`. A
temporary source-to-binary manifest at
`/private/tmp/neantik-m154-diagnostic-manifest-20260926.json` binds that
executable to source diff SHA-256
`8a8005bc49b43506b93f7ccaacd5ee930f3965b5f731bba66ff3f181f4037ef5`; the
final manifest SHA-256 is
`6ef080228996d4e71d40ea0bb69130a2a7309918835e0a50f8b398b0d140b1b3`.
This is diagnostic evidence only: at link time the source tree had 232 modified
tracked paths and 17 untracked inputs, and that build used a mixed SDK overlay
rather than a supported release toolchain. The source tree now has 237 modified
tracked paths and the same 17 untracked inputs; its current tracked diff SHA-256
is `b8c009518ee516bdd8aa9a2052fb5786e35e68fb88d0d4651a18b792025fd3f6`. The
binary's historical source manifest therefore does not bind the current source
tree. The headless `about:blank` smoke still aborts in
`TransformProcessType`/`InitHeadlessMode`. On 27 September, a separate GUI smoke
launched the same unsigned diagnostic binary with a fresh temporary user-data
directory; process arguments and created files confirmed that directory was
used, and loopback-only DevTools reported Chromium `154.0.8037.58` displaying a
local `data:` page titled `NeAntik-M154-Smoke`. External networking and
component updates were disabled. This verifies basic GUI startup, renderer
execution, and temporary-profile selection only; it does not prove
A→B→A persistence, production profile recovery, network privacy, or runtime
coherence. The captured successful link output remains
`/private/tmp/neantik-m154-link-final-20260926.log`.

The selected Safe Browsing and Safe Browsing content-browser unit-test source
sets now compile in mode 0. That required guarding test-process Safe Browsing
service APIs and keeping tests that require Safe Browsing-only response types
in the matching build mode. The combined monolithic `unit_tests` executable
still fails at ThinLTO link with Safe Browsing symbols excluded by mode 0; the
final incremental compile log is
`/private/tmp/neantik-m154-unit-test-compile-retry5-20260926.log`.

### Focused enterprise archive unit tests — 27 September 2026

A separate `enterprise_archive_analyzer_unittests` target was built in the
disposable M154 mode-0 diagnostic output. Its first harness used the generic
`base::TestSuite` runner and failed before archive assertions because Chrome
test-data paths and Mojo were not initialized. The disposable test target was
then wired to Chromium's `ChromeUnitTestSuite` (`chrome/test:test_support_unit`)
and rebuilt; no production browser code or Safe Browsing build flag was
changed for this harness correction.

The focused runner passed **50/50** ZIP, RAR, encrypted/obfuscated archive,
nested archive, and temporary-file unit tests. The captured log is
`/private/tmp/neantik-m154-enterprise-archive-tests-20260927.log`.

This closes only archive-parser and temporary-file unit coverage in this
diagnostic source tree. It does not prove Enterprise policy-to-upload-to-
verdict-to-download behavior, Mojo service binding or sandbox failure paths,
or Safe Browsing network/clipboard/IP/referrer privacy behavior. The source
tree and test target are diagnostic-only and are not release provenance.

### Focused Enterprise policy/verdict tests — 27 September 2026

A second disposable-only test target linked the Enterprise analysis unit-test
sources together with the mode-0 `TestBinaryUploadService` helper. Its first
focused run covered `ContentAnalysisDelegateAuditOnlyTest.*` and
`FilesRequestHandlerTest.*` and failed 2/46 encrypted-archive expectations.
Tracing the service path found that M154 registered `FileUtilService` only for
Safe Browsing download protection or ChromeOS, while Enterprise cloud analysis
still called its sandboxed archive analyzer with mode 0. A disposable-only
two-file change adds the Enterprise build gate to utility dependencies and
service registration; it does not turn on Safe Browsing. The exact patch is
`/private/tmp/neantik-m154-enterprise-service-gate.patch`
(SHA-256 `2690686133a46a3361d6b38849a4e67433c6be8d6991926ef71e7b8a6b8dbdc8`)
and its hunks pass `git apply --check` against the clean official M154 `.58`
checkout. This patch is not self-contained: it references the diagnostic-only
`enterprise_archive_analysis` GN argument/feature gates for the analyzer and
Mojo interfaces, which have not yet been ported into the clean owned source
manifest. Therefore the apply check proves hunk applicability only, not clean
GN generation or a clean M154 build.

After regenerating GN and relinking the utility/framework and focused test
runner, both encrypted-file tests passed and the full focused set passed
**46/46**. Log:
`/private/tmp/neantik-m154-enterprise-policy-focused-tests-fixed-20260927.log`
(SHA-256 `0cc56e130661b7073c512513b27fe02f1d6cdd7457e6e35f22efc448f94ad49b`,
8,509 bytes). This supports the diagnosis and verifies policy-to-archive
verdict handling in the diagnostic harness. The patch remains outside the
product's owned M154 patch manifest; clean replay/build, utility-process
crash/disconnect behavior, sandbox denial, end-to-end download handling, and
Safe Browsing negative privacy assertions remain open. Do not weaken the test
expectations or disable Enterprise scanning to get green results.

The Xcode Beta was not reinstalled or switched during this pass. A second
pre-existing `/Applications/Xcode.app` is also Xcode 27.0 (`27A266a`); the
selected copy remains Xcode Beta 27.0 (`27A5228h`). Both expose SDK 27.0, not
the M154 official-build pin 26.5 / `25F70`. The pinned Chromium CIPD package is
not installed locally; a read-only `cipd describe` request for the M154 package
returned that it is not visible to unauthenticated callers. No login or package
download was attempted. Installing another Xcode is not the missing gate.

### Existing Xcode 27 diagnostic follow-up — 26 September 2026

The second Xcode 27.0 installation (`27A266a`) is present alongside Xcode-beta
(`27A5228h`); `xcode-select` remains pointed at the beta. Its SDK is 27.0 / build
`26A425` and contains `mach/exc.defs`, which is missing from the beta SDK.
M154's checked-in Chromium toolchain config pins the official SDK to
26.5 / build `25F70` and uses a hermetic toolchain for official branded builds.
The M154 source references an internal CIPD package; a fresh read-only lookup
was not visible to unauthenticated callers, and no package download was
attempted. Chromium's Mac build instructions say a newer SDK usually works, so
the local 27.0 SDK is not by itself a Chromium build blocker. NeAntik's release
process still requires a complete, reproducible toolchain and exact-source
qualification; neither installed 27.0 copy has passed that full qualification
yet. Installing another Xcode is not required to continue.

A fresh output, `out/NeAntikStableXcodeDiagnostic`, was GN-generated against the
second Xcode installation's SDK without the previous SDK overlay. The M154
`chrome` target compiled
12,743 of 49,767 remaining actions before it was intentionally interrupted;
the completed actions included Metal shader generation and ANGLE/Metal
Objective-C++ sources, with no compiler or Xcode/SDK failure. The first
sandboxed attempt could not write Apple's shared `~/.cache/clang` module cache;
the same build resumed in the permitted macOS context and passed that target.
This output used `mac_allow_system_xcode_for_official_builds_for_testing=true`,
so it is diagnostic only: no app was linked, no tests ran, and it does not meet
the pinned hermetic release-toolchain gate. The partial output is preserved in
the disposable source checkout; no source files were changed by this attempt.

The targeted NeAntik `ProfileStoreTests` suite passed on 26 September (38/38),
including atomic background import, rollback, caller cancellation semantics,
and 5,000-profile/folder synthetic import. Its benchmark reported 5,000
profiles and 5,000 distinct folders imported in 1.366 seconds; startup for
10,000 profiles took 0.142 seconds and the launch marker update 0.335 seconds.
These are local manager measurements, not a Chromium/runtime benchmark. No
release source commit, artifact, signature, notarization submission,
publication, or site deployment was produced.

1. Resolve Chromium source, patch, toolchain, and runtime-lock differences in
   the runtime workstream. Verify source provenance, patch survival, build,
   isolation, and runtime behavior before preparing a candidate.
2. Start from one clean exact source commit and create a candidate with a
   deliberate version/build increment.
3. Bind source, runtime hashes, manager tests, isolation evidence, and package
   manifest to that commit. Run Developer ID signing, Apple notarization,
   stapling, Gatekeeper, and fresh local artifact verification.
4. Upload ZIP/DMG and checksum sidecars to GitHub Releases; verify uploaded
   bytes against candidate hashes.
5. Update browser.free only after artifact gates pass; verify the live page and
   `/api/release` agree on version, build, archive, and SHA-256.
6. Confirm `v0.7.10` remains available as rollback and test the public download
   path before declaring the release complete.

NeAntik is Direct Distribution only; do not use Mac App Store or App Store
Connect. Never publish a stale candidate to bypass a failed runtime gate. Keep
certificates, notary credentials, proxy secrets, cookies, raw network evidence,
and private fingerprint data out of Git and public release metadata.


### Enterprise mode-0 download policy test and fresh release state — 27 September 2026

A disposable-only focused runner isolated `ShouldObfuscateDownload()` from the
Safe Browsing-only test fixture. With `SAFE_BROWSING_DOWNLOAD_PROTECTION=0`
and Enterprise content analysis enabled, the regression test passed **1/1**:
a block-until-verdict `FILE_DOWNLOADED` policy enables obfuscation, while a
report-only policy does not. Log:
`/private/tmp/neantik-m154-download-policy-test-20260927.log` (SHA-256
`6708e9df4a72829eac493055c311f2763e6b260593871669655c922422c21df0`, 1,130
bytes). The first sandboxed run could not create the test profile's temporary
directory; the identical test passed in the permitted macOS context. This is
unit coverage of one policy decision only, not end-to-end download, upload,
verdict, Mojo disconnect, sandbox-denial, or privacy evidence. The isolated
runner and regression-test edits exist only in the disposable M154 tree and
have not been added to the owned M154 patch manifest.

Fresh external checks show immutable GitHub release `v0.7.11` / build `74`
with the same ZIP/DMG SHA-256 values recorded above. Sites version 98 from
`827e7231d0a756063425387d4c635d7066fa0424` has a succeeded deployment. Live
`/api/release` still reports `canDownload=false` because Chromium
`153.0.8010.52` is below its `154.0.8037.58` baseline. In the permitted
macOS context, four valid signing identities (including two Developer ID
identities) were visible and `xcrun notarytool history --keychain-profile
neantik-notary` succeeded; the existing 0.7.11 ZIP and DMG submissions are
Accepted. These are release credential/readiness checks only and do not qualify
an M154 candidate. Xcode Beta remains selected (`27.0`, `27A5228h`); no Xcode
was installed or switched.


The current disposable Chromium diff snapshot after adding the isolated test
harness is 240 modified tracked paths / 365,203 binary-diff bytes, SHA-256
`b19292fa62f314cd69e82ee2a042df2aa93889cde42041b15ce2fd57aa4ec3e8`, plus
13 untracked inputs (path inventory SHA-256
`3ef2bd0c26e4b3d34de69c765f1036422f44dc711a13090a8692360a93524429`). This
hash supersedes the earlier diagnostic-tree diff hash. The additional harness
and regression test are disposable diagnostics only; none are promoted to the
product-owned M154 patch manifest.


### Utility-service Mojo disconnect regression — 27 September 2026

The disposable M154 enterprise archive runner now includes a focused
`SandboxedZipAnalyzerTest.FileUtilServiceDisconnectCompletesEnterpriseAnalysis`
test. It destroys the `FakeFileUtilService` peer after the nested analyzer bind
is sent and verifies the ZIP analyzer's disconnect handler completes the
Enterprise callback with an unsuccessful result. Safe Browsing download
protection remains off. The focused archive/temporary-file suite passes
**51/51**, including this regression. Log:
`/private/tmp/neantik-m154-enterprise-archive-tests-plus-disconnect-20260927.log`
(SHA-256 `2b8d9447e09980111d07d5fadc3b4d66a1bfd0e85473b743191ef30eefa3b0b1`,
16,630 bytes). This exercises Mojo peer disconnect, not an OS utility-process
crash or sandbox-denial case. The test and runner remain disposable-only; no
M154 patch was promoted to the product-owned manifest.

The resulting disposable source snapshot is 241 modified tracked paths / 367,325
binary-diff bytes (SHA-256
`815bf6019327a58f2a58eead6b56e14b53d419669b8a8df61159d837c09b73f6`) and 17
untracked inputs (path inventory SHA-256
`8ff4ebecb278fcc0d6be20e24c2910578bd1a4f6cea7858a0beffd5dc4e4388f`). It
remains diagnostic-only and is not reproducible from the owned M154 patchset.

### Clean M154 Enterprise mode-0 port attempt — 27 September 2026

A curated 36-file Enterprise archive-analysis patch (61,234 bytes; SHA-256
`6e4e7c76a599d0fa1d9820694ac50e3f0b643d22aa3cefcc3c56d5da7a5b2827`)
passed `git apply --check` on clean Chromium 154.0.8037.58 commit
`a654841425914cbb703a2931e07b70a83aedbafd`. GN evaluation with
`safe_browsing_mode=0` and Enterprise cloud/local content analysis enabled
then failed the complete graph check: feedback, suspicious-site warning, and
browser/interactive test targets still require Safe Browsing blocking-page or
client-side-detection targets that are not defined in mode 0. The relevant
consumers need explicit conditional ownership or separate Enterprise-safe
support targets before this patch can configure as a whole. No compile was
attempted. GN used a disposable overlay of locally available pinned submodule
checkouts and generated dependency inputs; this is not a reproducible clean-room
build. The attempt did not change the product-owned Chromium manifest, build a
candidate, sign, notarize, upload, publish, or deploy. Details and unresolved
targets are recorded in `runtime/chromium-154-diagnostic-status.json` under
`cleanEnterpriseMode0PortAttempt`.

A follow-up diagnostic port added the corresponding mode-0 consumer guards and
conditional Enterprise file-type-policy dependencies. GN generated 34,845
configured targets without unused-argument errors. Target-scoped GN header
checks passed for `//chrome/browser/download:impl`,
`//chrome/browser/download:unit_tests`,
`//chrome/browser/safe_browsing:unit_tests`,
`//chrome/services/file_util:unit_tests`, and `//chrome/browser/ui:ui`.
The full-tree header check still reports 10 include-dependency errors across
extensions, file-system access, policy/preferences, zlib ZIP consumers, and a
Safe Browsing search-engine dependency. This is an incomplete diagnostic port;
no Chromium compilation or runtime test was run from this clean-source worktree.
The results are target-scoped diagnostics, not a candidate or release gate.

### Ordered owned-patch M154 replay — 27 September 2026

The first M154 ordered-patch experiment used an incomplete source checkout and
an invalidated dependency snapshot; its earlier `100/109` result and nine
conflicts are superseded by the full dependency replay below. The owned-patch
port starts from official Chromium `.58` commit
`a654841425914cbb703a2931e07b70a83aedbafd`. All 11 NeAntik runtime groups
passed sequential `git apply --check` and application in manifest order on an
APFS copy of the full replay. The timezone group needed its
`CoreInitializer::Initialize()` context moved from the removed
`ScriptStateImpl::Init()` call to M154's `BindingSecurity::Init()` sequence;
the private-environment and cached-seed groups then applied after their
prerequisite groups. Ported patch copies and exact hashes are preserved under
`runtime/nevision-patches/ports/chromium-154.0.8037.58/`.

This proves patch applicability only. The canonical
`runtime/nevision-patches/series.json` still targets Chromium 152, and its
11/11 manifest validation plus 22 verifier tests do not validate M154
postimages or behavior. The M154 macOS packaging layer and source lock are not
ported, and the experiment was not compiled or runtime-tested. Keep it out of
the release-candidate path until these source and toolchain gates are closed.
The fresh upstream GitHub API listing also found only the `master` branch and
latest macOS packaging tag `152.0.7977.82-1.1` at commit
`038db2b41f7aeb00bbceb2f5a56912b26eb5b284`; no M154 macOS ref is published.

### Fresh full-dependency M154 replay — 27 September 2026

A separate clean `.58` checkout was synchronized using the existing
`gclient sync --nohooks -j6` configuration and all pinned DEPS, then processed
with the official common-layer pruning and `utils/patches.py apply` commands.
All **109/109** patches from `154.0.8037.57-1` applied with no logged fuzz,
offset, ignored patch, missing file, or reject. The dependency map has 240
revision entries (SHA-256
`cf2e1f865c9c6977c83fb4b1998d1e38376593c367a7ba678655f19df75cfe89`). The
11 owned M154 patch copies then passed sequential checks on a separate APFS
copy of that common-layer tree. Evidence is recorded in
`runtime/nevision-patches/ports/chromium-154.0.8037.58/port-experiment.json`.

This closes the earlier common-patch applicability conflict, but does not
establish a reproducible NeAntik source lock: the replay still lacks the M154
macOS packaging layer, generated postimage hashes, and semantic/runtime
qualification. The live GitHub API still reports macOS packaging release
`152.0.7977.82-1.1` at `038db2b41f7aeb00bbceb2f5a56912b26eb5b284`; no M154
packaging ref was found. Xcode 27 is already installed and selected Beta stays
active; no additional Xcode installation is needed. A partial system-SDK
compile is not a clean build or release qualification.

### M152 macOS packaging patch port probe — 27 September 2026

Pinned and verified the upstream packaging checkout at commit
`038db2b41f7aeb00bbceb2f5a56912b26eb5b284`, tree
`977597e8e338be52f44d282f885ed33c025b3122`. Its 16-patch series was applied
in order to a separate copy of the clean M154 common-layer tree. Ten patches
applied cleanly; six have M154 conflicts: `build-bindgen`,
`disable-clang-version-check`, `fix-disabling-safebrowsing`, `fix-dsymutil`,
`build-bindgen-target-override`, and `bindgen-disable-static`. Exact series and
log hashes plus per-patch outcomes are recorded in
`runtime/nevision-patches/ports/chromium-154.0.8037.58/port-experiment.json`.

The Safe Browsing packaging patch also removes a generic macOS utility
dependency and Safe Browsing-only UI/test dependencies. The NeAntik M154
Enterprise archive-analysis gate must restore the utility dependency under
`enterprise_archive_analysis` while keeping `safe_browsing_mode=0`; this
interaction is not yet build- or runtime-verified. No packaging port or binary
candidate has been accepted from this probe.

### M154 feature-preservation follow-up — 27 September 2026

Review of the M152 packaging series found additional M154 behavior removed by
its Safe Browsing compatibility patch: guarded per-user/per-browser Enterprise
Client Certificate policy entries and the macOS ScreenAI and On-device
Translation sandbox parameters. Added the post-packaging restoration patch
`runtime/nevision-patches/ports/chromium-154.0.8037.58/patches/macos-feature-preservation.patch`
(SHA-256
`e128b89aeefe51a9a775322627c40f3dc51cda518edf1a8aff2f12b57383d14b`).
`git apply --check` and application passed on the isolated packaging-port and
cleanprobe trees; reverse-application and source-preservation checks also
passed. Safe Browsing mode remains 0.

The cleanprobe GN header check passes for `//chrome:chrome`. Its generated
graph confirms Enterprise Cloud Analysis is enabled, the derived
`enterprise_archive_analysis` condition is true on macOS, ZIP and RAR analyzer
sources are present, and the focused
`//chrome/services/file_util/public/cpp:enterprise_archive_analyzer_unittests`
target exists. The full `chrome` build has resumed on this restored source.
GN generated the SDK link while Xcode Beta was selected; it resolves to the
Beta SDK 27.0 build 26A5388f. The Ninja process receives
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` so `xcrun` can
resolve the already-installed Apple Metal toolchain; the command requests
toolchain label `32023.921.5`, but the resolved compiler reports
`32023.921.6`, while Beta reports its bundled Metal Toolchain missing. A
no-compile probe through
`scripts/runtime-tools/xcrun` selected the same `metal` and `metallib`
binaries with `DEVELOPER_DIR=Xcode-beta` and an explicit path to that existing
Metal component. This proves a full-Xcode install is unnecessary and gives a
cleaner Beta invocation for the next build. The current build remains
diagnostic-only under Chromium's system-Xcode testing override. Chromium
documents 26.5 build 25F70 as its known-good official pin and says a newer
SDK usually works. Compilation is still in progress, and no
post-restoration Enterprise test runner or runtime/GUI gate has completed.

This overlay does not close the six unresolved M154 packaging patch contexts,
generate source/postimage locks, or establish exact source-to-binary
provenance. The public 0.7.11 release remains the rollback release and
browser.free keeps downloads disabled. No signing, notarization, upload, or
publication was performed. Current machine-readable build and gate state is
recorded in `runtime/nevision-patches/ports/chromium-154.0.8037.58/port-experiment.json`.

### M154 canonical tuple overlay correction — 27 September 2026

The manual `ninja chrome` diagnostic had skipped the owned generated-data
layer. Its provisional five-row Apple tuple arrays did not match the reviewed
11-row catalog in `runtime/apple-device-tuples.json`; that partial build was
stopped at 12,798/29,164 actions and is not accepted as product build evidence.

Added `scripts/apply-owned-runtime-device-tuples-154.py`, a version-locked
M154 wrapper around the existing reviewed tuple renderer. It binds Chromium
commit `a654841425914cbb703a2931e07b70a83aedbafd`, tree
`63b6339af403b6f8dc70fe2d4613f91f1c04f43a`, the canonical catalog digest, and
all eight exact generated postimages. The 11-row header was applied to the
isolated macOS-packaged source; the wrapper's `--check`, the catalog verifier,
and the three M154 overlay unit tests pass. GN regenerated 35,007 targets and
`gn check out/NeAntikM154PortProbe //chrome:chrome` passed.

A corrected `ninja -j6 chrome` is now running against that source, using the
installed Xcode 27 system SDK with the explicit diagnostic testing override.
The graph restarted at 278/50,958 actions after GN regeneration. This is not a
hermetic pinned-SDK build or a release candidate. The six M152 macOS packaging
patch conflicts, M154 source/postimage lock, Enterprise crash/disconnect and
sandbox tests, mode-0 unit-test boundary, exact runtime A→B→A and privacy
qualification, and signing/hosted-release gates remain open. Safe Browsing
mode stays 0, downloads stay disabled, and v0.7.11 remains the rollback.

Toolchain clarification: Xcode Beta 27.0 remains selected and no Xcode or
component was installed, removed, or replaced. The active Ninja graph's SDK
symlink points to the Beta SDK (build 26A5388f). Beta itself lacks its bundled
Metal Toolchain, but the system has an Apple MetalToolchain 32023.921.6. The
existing `scripts/runtime-tools/xcrun` wrapper successfully routes both
`metal` and `metallib` to that component while `DEVELOPER_DIR` remains Beta;
the version probe passed without compiling anything. The current run uses
the regular Xcode only for `xcrun` discovery; its Metal compiler is that same
standalone component. This can be reproduced without installing another
Xcode. Chromium's official M154 CI pin remains SDK 26.5 build 25F70, while
its macOS guide says newer SDKs usually work. The candidate still needs an
exact source/toolchain record and all runtime, signing, and release gates.
The pinned private CIPD bundle is not in the local cache, and DNS resolution
for its service failed during the read-only probe.

At 2026-09-27 01:59 UTC the corrected diagnostic Ninja session 5467 was still
live at 20,801/50,953 actions with no compiler errors reported.
`scripts/export-chromium-154-port-input-manifest.py` now binds the exact M154
base, 11 owned patch digests, Apple tuple generator/catalog, Safe Browsing mode
and GN args. Its five focused tests pass. The export correctly fails closed on
the active packaging-cleanprobe because it contains 13 untracked `.rej`
patch artifacts from unresolved M152 macOS packaging hunks. Their intended
changes need an owned M154 port; the reject files were not removed or excluded.
The current Ninja output therefore remains diagnostic only and cannot be
promoted to a release candidate.

The active source remains pinned to Chromium 154.0.8037.58 commit
`a654841425914cbb703a2931e07b70a83aedbafd` / tree
`63b6339af403b6f8dc70fe2d4613f91f1c04f43a`. A fresh version probe with
`TOOLCHAINS=com.apple.dt.toolchain.Metal.32023.921.5` returns the already
mounted Metal compiler version `32023.921.6`; no Xcode or Metal component was
installed or downloaded. The compiler remains reachable through the explicit
NeAntik resolver while Xcode Beta is selected.

### Fresh continuation checkpoint — 27 September 2026

GitHub connector access was freshly verified: `AffPapa/neantik` reports
admin/push permission. The latest release remains immutable `v0.7.11` / build
74, bound to `fa3b03cbe122840ea308d2ecf19004a1128a1a06`; its ZIP and DMG
digests match the release metadata already recorded above. The live
`browser.free/api/release` response independently still reports build 74,
`published-runtime-gated`, `canDownload=false`, and Chromium
`153.0.8010.52` below baseline `154.0.8037.58`.

The GitHub connector can read the repository and reports admin/push permission.
A fresh local `gh auth status` check reports the stored CLI tokens for both
AffPapa and mrdumay-source as invalid. This does not negate connector access,
but the CLI release-asset upload path must be reauthenticated or replaced by
another verified upload route before publication. No login flow was started
while there is no releasable candidate.

The currently available browser session is also signed out of GitHub (the
release-list page shows Sign in). The GitHub app connector remains
authenticated, but it exposes read and repository APIs rather than large
release-asset uploads. Before a candidate is ready, resolve publication
through a renewed CLI login or another explicitly verified signed-in upload
path; do not infer browser authentication from connector access.

The current shell confirms `/Applications/Xcode-beta.app` is selected
(Xcode 27.0, build `27A5228h`). The already-installed
`/Applications/Xcode.app` is also Xcode 27.0 (build `27A266a`); both expose
macOS SDK 27.0. Default `xcrun metal` reports that the Metal component is
missing even though `xcrun --find metal` returns a path. The existing Metal
Toolchain is mounted from Apple's cryptex and should be located dynamically
with `TOOLCHAINS=com.apple.dt.toolchain.Metal.32023.921.5 xcrun --find metal`;
its `metal` and `metallib` binaries work through
`scripts/runtime-tools/xcrun` succeeds with Xcode Beta selected. No Xcode or
Metal component was installed. Beta's SDK remains the generated GN SDK; the
ongoing diagnostic build uses the already-installed regular Xcode for Metal
tool discovery. This mixed/testing-override setup is not a release-toolchain
qualification.

The 32 focused Python tests for M154 manifest export, owned tuple overlay, and
patchset verification pass. The active six-job diagnostic Ninja session 5467
advanced from 20,801 to 26,846 of 50,953 actions without a reported compiler
error. This source still contains 13 untracked `.rej` files; the manifest
exporter intentionally rejects it, so a successful link would remain
diagnostic, not promotable. No candidate was signed, notarized, uploaded, or
published, and no public state changed.

The read-only Keychain check was repeated in the permitted macOS context after
the sandboxed attempt returned a Keychain-access error (that error was not
interpreted as missing credentials). Two valid Developer ID Application
identities were visible, and the `neantik-notary` profile returned 100 history
records. The newest accepted item is `NeClip-2.8.7.dmg` from 26 September;
this proves the credentials work, but provides no signature or notarization
evidence for a NeAntik M154 candidate.

The exact active diagnostic source confirms `safe_browsing_mode=0` and
`enterprise_cloud_content_analysis=true` in `args.gn`. Its macOS-derived
`enterprise_archive_analysis` gate includes ZIP/RAR analyzer sources and the
FileUtilService registration path; GN also defines
`//chrome/services/file_util/public/cpp:enterprise_archive_analyzer_unittests`
for mode 0 with Enterprise analysis enabled. This is configuration evidence
only. Its source list contains sandboxed ZIP/RAR analyzer and temporary file
getter tests; SevenZip and DMG analyzer tests are excluded in mode 0. Run the
focused target after the active `ninja chrome` finishes to avoid concurrent
Ninja writers and obtain behavioral test evidence.

The manager-side `swift test --jobs 2 --filter ProfileStoreTests` passed
38/38 on this source tree. It includes the background import, rollback-on-
folder-persistence-failure, and symlink recovery cases. Its 5,000-profile,
5,000-distinct-folder benchmark completed in 2.51 seconds on this machine;
this is a single-run observation, not a before/after performance claim.
The full `swift test --jobs 2` suite also passed: 636 tests across 70 suites.
The full Python regression suite passed 700 tests with one environment-gated
skip.

### Active M154 diagnostic build checkpoint — 27 September 2026 16:12 UTC

The resumed Ninja process `14175` is still live. Its current log reports
`1955/34973` actions for `net_unittests` and
`enterprise_archive_analyzer_unittests`; no compiler error or Ninja failure
has appeared since the unused-signin-helper fix. It is compiling Blink layout
objects. This is a verified in-progress wait, not a completed build or test
result. The diagnostic tree and release gates described above remain unchanged.
The build uses already-installed Xcode 27.0 (`27A266a`) process-scoped; the
global `xcode-select` still points to Xcode Beta. No Xcode was installed or
globally selected for this run.

The mode-0 review confirms the fresh `args.gn` records
`safe_browsing_mode=0` and `enterprise_cloud_content_analysis=true`. The
Enterprise archive target covers local ZIP/RAR and temporary-file behavior;
it does not establish provider upload/verdict or network privacy. After this
Ninja run exits successfully, run only the already-built test executable before
considering any further build. Utility process crash/restart, OS sandbox
denial, provider fail-closed behavior, and proof that no Safe Browsing upload
or download-protection request occurs remain separate runtime gates.

The read-only macOS packaging review of the six M152 patch conflicts against
M154 found no safe wholesale transplant. Preserve M154's clang revision guard
and bundled dsymutil path; do not apply the literal M152 replacements. Three
bindgen conflicts form one coupled change and should be ported only if a clean
arm64 M154 build demonstrates the dependency/path failure, then validated by
generation and a downstream Rust consumer. The necessary behavioral packaging
slice is the narrow Enterprise archive-analysis gate under the Enterprise
feature while Safe Browsing remains disabled; avoid the stale broad Safe
Browsing UI dependency deletion. Current M154 diagnostic source is still not a
clean replay or release candidate.

At 16:23 UTC the same Ninja session had advanced to `2561/34973`, with no
failure in the log. Neither requested test executable exists yet in the exact
output directory, so no test runner has been started.

That Ninja run then exited 1 at action `2840/34973`: Clang rejected the
unreachable implementation body after the common overlay's unconditional GCM
MCS early return. The body was already disabled; I removed that dead block and
the two now-unused declarations only, preserving the early return. The new
owned M154 patch is `m154-remove-unreachable-disabled-gcm-body.patch` (SHA-256
`39c2fac5ab57d17e07d830b03969fa262c2b36773ce8f4229d6f8c0f550e553b`). It
applies cleanly to the exact common-overlay tree, and the affected
`gcm_client_impl.o` compiles with the existing stable Xcode 27 compiler. The
M154 exporter/test expectation is now 13 owned patches; the full test-target
build must resume before behavioral tests can run.

The targeted exporter regression passes 10/10, and the updated M154 test build
has resumed in session `63864`; at 16:33 UTC it reached `160/32128` actions
with no reported compiler failure. Its log is
`/private/tmp/neantik-m154-testbuild-resume3-20260927.log`.

That resume stopped at action `275/32128` on another Clang `-Werror`: the
ungoogled overlay's constant-true Domain Reliability discard guard made the
Google upload implementation unreachable. I preserved its always-discard
behavior and synchronous success callback, removed the dead upload body and
now-unused MIME/traffic-annotation declarations, and confirmed the affected
`uploader.o` compiles. The exact overlay accepts the new owned patch
`m154-remove-unreachable-domain-reliability-upload-body.patch` (SHA-256
`f359a7265dba9ffc5c2a4e01aad2f91a13a3de36fc5b65f5bddab6bc626f8428`). The
M154 port now records 14 sequential patch groups; its exporter regression
passed 10/10, and the full targets resumed as session `92926`. At 16:38 UTC it
was at `836/31848` actions with no reported compiler failure. The new log is
`/private/tmp/neantik-m154-testbuild-resume4-20260927.log`.

Fresh external checks on 27 September: GitHub API still returns immutable
`v0.7.11` / build 74 at source commit
`fa3b03cbe122840ea308d2ecf19004a1128a1a06`; the ZIP, DMG and two SHA-256
sidecars are present and their API digests match the release evidence. The
Sites connector identifies the active public `browser.free` project as
version 98. Direct `/api/release` retrieval from this shell failed DNS lookup,
and the web fetcher could not access that endpoint; therefore its live response
was not reverified in this pass. Local `gh auth status` still reports both CLI
tokens invalid, despite successful GitHub connector reads.

The permitted macOS Keychain check now succeeds: four valid signing identities
are available, including two Developer ID Application identities;
`neantik-notary` returns accepted submission history. The newest visible
submissions are NeClip 3.0.1, which proves profile access only; it does not
prove signing or notarization for an M154 NeAntik candidate.

The next compile stop was `template_url_service.cc` (`-Wreorder-ctor`):
`should_autocollect_` was initialized before fields declared ahead of it. The
owned patch `m154-template-url-service-init-order.patch` moves only that
initializer into declaration order and preserves its `true` value. Its SHA-256
is `0ecc9192845a88690e0428b39993faf5b3c71e01aeccaf076a0678498d07f032`; the
affected object compiles successfully. The M154 port now records 15 owned
patches and the exporter regression expects all 15. A new Ninja session 19685
is running `net_unittests` and `enterprise_archive_analyzer_unittests` from
`/private/tmp/neantik-m154-unpruned-root/src`, log
`/private/tmp/neantik-m154-testbuild-resume5-20260927.log`, with `-j6` and
process-scoped Xcode 27.0. Ninja noted its prior build-log format was old and
restarted that local log; the run remains in progress and has not produced
test results.

The fresh GN distinction is also recorded: `gn check //chrome:chrome` passes
in the macOS packaging cleanprobe, while unfiltered `gn check` fails after its
default 100-error cap across test/support dependency graphs. The product
target check is not evidence that the complete GN graph passes.

The original Enterprise archive/M154 mode-0 experiment was not replayable
unchanged over the ungoogled common overlay. I kept its diagnostic patch
immutable and generated
`patches/enterprise-cloud-archive-analysis-mode0-common-overlay.patch` with
with unrelated superseded hunks omitted and an owned mode-0 guard added for the
renamed `multipart_uploader.cc` path. The rebased patch contains 34 files,
SHA-256
`86d2fa0d4ad24a97f205e1a00d2ebe27c60f85f5b844363ea974331fb51731a9`; it parses
as a 34-file patch and is ordered group 16. The full patch now passes
`git apply --check` after groups 1-15 in the pinned full-DEPS/common sparse
replay. The three relevant upload
diagnostic sites have a separate combined applicability check against the
clean official M154.0.8037.58 commit: the pinned common patch removes the
`FilesRequestHandlerBase` and resumable-uploader calls, and the owned group
guards the renamed multipart uploader call. The combined check passes. This
does not qualify the full ordered source replay, GN graph, or runtime; service
crash/sandbox/provider tests remain open.

The pinned ungoogled-chromium commit
`a638756eb14c8b6ce64b4b2a067afea5d4207bf4` contains
`fix-building-without-safebrowsing.patch`; a fresh GitHub raw read measured
175,769 UTF-8 bytes and SHA-256
`74788df8163ba56909c8fe55938b85a6af1ecbfeb99e773bc7c5b4a1bfb41682`. Its
hunks remove two calls that update `chrome://safe-browsing` diagnostics; its
third hunk targets the old `multipart_uploader_base.cc` path, which is absent
on M154.0.8037.58.
The earlier recorded SHA `b0be19d0e00a0c1dd9671c3e74cc84b61198cf401e379606bd9ee3c06d017f79`
was wrong for this pinned file. I combined the two applicable upstream hunks
with the owned guard for the renamed multipart path; this temporary patch
(`2daef49892978f713d2df301fa0651e70885ee4c4de655edc16c80418d2e7b27`) passes
`git apply --check` on the pristine `.58` checkout at `a654841…`. The full
upstream patch still fails elsewhere on `.58`, and the recorded `.60` replay is
also not clean. The selected call-site ownership issue is now addressed, while
the complete source replay remains a release blocker.

The first resume of this large test graph stopped at ANGLE's Metal shader
action, which attempted to write PCM modules below
`$HOME/.cache/clang/ModuleCache` and hit sandbox `EPERM`. This was not a
Chromium C++ diagnostic. In the permitted macOS context, both executables in
the already-installed Metal Toolchain `32023.920.1` passed strict signature
verification; the repository's `verify-metal-toolchain.sh` then compiled its
Metal fixture to AIR and linked a metallib successfully (compiler
`32023.921`). Ninja resumed at session 85039 with the repository xcrun wrapper
and isolated scratch caches under `/private/tmp`. The refreshed graph has
53,999 actions; the current log is
`/private/tmp/neantik-m154-testbuild-resume6-20260928.log`. This remains a
diagnostic build using existing Xcode/Metal components, with Xcode Beta still
globally selected and no toolchain installed or selected globally.

At 2026-09-27 17:13 UTC, the resumed Ninja session 85039 was live at
`5472/53999` actions with no compiler error since the retry. Keep the current
run intact; do not clean or start a competing Ninja process.

The canonical build/release path was checked in source. `series.json`,
`build-runtime.sh`, and `prepare-runtime-source.sh` are tied to M152; the
runtime verifier has a separate M153 compatibility path but no M154 contract
selector, and `Run-NeAntik-Release.command` defaults to
`/private/tmp/nevision-chromium-152/build/source-provenance.json`. The
diagnostic M154 manifest exporter is not wired into those entrypoints. Do not
run the release command against the M154 experiment until a clean M154 source
contract, build selector and package provenance path are implemented and
tested.

The latest Metal record supersedes older version text in this handoff: the
mounted, signature-verified bundle has identifier
`com.apple.dt.toolchain.Metal.32023.920.1`, its compiler reports
`Apple metal version 32023.921`, and its smoke AIR/metallib outputs pass. Do
not use the older `32023.921.6` note as the current bundle identity.

At 2026-09-27 17:40 UTC, Ninja session 85039 was live at `12498/53999` actions;
the log still showed no compiler failure after Metal cache routing. This process
uses the already-installed stable Xcode 27.0 via `DEVELOPER_DIR`; the machine's
global selection remains Xcode Beta. No Xcode was installed or globally switched.

At 2026-09-27 18:19 UTC, session 85039 remained live at `18658/53999`; the
requested test targets are still compiling and no test binary has been run.
Fresh GitHub connector reads in this continuation show `v0.7.11` remains the
latest immutable release (source `fa3b03cbe122840ea308d2ecf19004a1128a1a06`)
with notarized Apple Silicon
DMG SHA-256 `fa0489a57b790f51f3d8eea0fa2b4d816bf9a123559f9fd0da71e0ddab6521f4`
and ZIP SHA-256 `141ffacec0fb601a9e20fa722b348bc6eed444132efee9c72ab582b5645d3576`.
The Sites connector still reports `browser.free` active at saved version 98,
updated 2026-09-26; its exact v98 deployment status is `succeeded` and its source
commit is `827e7231d0a756063425387d4c635d7066fa0424`. Direct `/api/release` verification remains unavailable in
this environment: shell DNS lookup failed and the in-app browser blocked the
request, so this is not evidence that the live site is down. GitHub connector
read access works; local `gh auth status` reports both saved CLI tokens invalid.

In an approved, non-sandboxed read-only Keychain check, four valid signing
identities were found, including two Developer ID Application identities. The
`neantik-notary` profile lookup returned “No Keychain password item found” for
the selected login keychain; that lookup alone did not establish profile
availability. A fresh approved `xcrun notarytool history --keychain-profile
neantik-notary --output-format json` succeeded and showed the 0.7.11 ZIP and
DMG submissions as `Accepted` on 2026-09-24. The existing notary profile is
usable for history; no new submission was made and no credentials were printed
or changed. Preserve the Developer ID identities.

The Enterprise archive patch now handles the three Safe Browsing WebUI call
sites explicitly: on clean M154.0.8037.58, the pinned upstream patch's two
matching removal hunks plus the owned mode-0 guard for the renamed
`multipart_uploader.cc` path pass together under `git apply --check`. The
selective proof is `/private/tmp/neantik-m154-mode0-upload-webui-gates.patch`,
SHA-256 `2daef49892978f713d2df301fa0651e70885ee4c4de655edc16c80418d2e7b27`.
All 16 owned groups now pass an ordered sparse replay of their exact 62 touched
paths, copied from the pinned upstream common+full-DEPS source state. Group 2
was rebased against the common overlay's existing image-noise implementation;
its patch SHA-256 is
`32046d721722653b9484469283902577d360bb075b178c7bc4b1f32b69e3365e`. Group 16's
multipart uploader context was rebased after groups 1-15. The final
group-16 patch is 34 files / 57,927 bytes with SHA-256
`86d2fa0d4ad24a97f205e1a00d2ebe27c60f85f5b844363ea974331fb51731a9`. Exporter
tests pass 10/10. This proves patch applicability on touched files only: the
full checkout still needs clean replay and regenerated source/postimage hashes.
The diagnostic checkout has six additional GN initializers in
`chrome/browser/safe_browsing/BUILD.gn` outside the owned 16 groups. The full
GN graph and runtime gates remain unqualified; keep `safe_browsing_mode=0` and
do not release from this diagnostic tree.

### Live checks — 2026-09-27 18:55 UTC; source/build recheck 18:55 UTC

GitHub connector read `/releases/latest` again and returned immutable
`v0.7.11` (build 74), source commit
`fa3b03cbe122840ea308d2ecf19004a1128a1a06`, ZIP SHA-256
`141ffacec0fb601a9e20fa722b348bc6eed444132efee9c72ab582b5645d3576`, and
DMG SHA-256
`fa0489a57b790f51f3d8eea0fa2b4d816bf9a123559f9fd0da71e0ddab6521f4`.
The Sites connector reports browser.free version 98, source commit
`827e7231d0a756063425387d4c635d7066fa0424`, deployment `succeeded`. Direct
`/api/release` fetch remains unverified because shell DNS resolution failed and
both web fetch routes were inaccessible; this does not establish an outage.
An approved read-only Keychain query found four valid signing identities,
including two Developer ID Application identities. The saved `neantik-notary`
profile successfully queried Apple submission history; latest NeAntik ZIP and
DMG remain `Accepted` from 2026-09-24, with no M154 candidate submitted. The
current test Ninja session 85039 was live at `21163/53999`, with no build
failure in the log and neither requested test target completed. Its active
`args.gn` at
`/private/tmp/neantik-m154-deps-sync-20260927/src-macos-packaging-cleanprobe/out/NeAntikM154PortProbe/args.gn`
confirms `target_cpu="arm64"`, `safe_browsing_mode=0`, and
`enterprise_cloud_content_analysis=true`. This configuration still belongs to
the diagnostic tree with 312 `.rej`/`.orig` files; it is not clean source or
release evidence.

### Live release and toolchain recheck — 2026-09-27 19:01 UTC

A fresh authenticated GitHub connector read of `/releases/latest` still returns
immutable `v0.7.11` / build 74, source commit
`fa3b03cbe122840ea308d2ecf19004a1128a1a06`. The API lists the notarized ZIP
and DMG with SHA-256 values matching the release evidence:
`141ffacec0fb601a9e20fa722b348bc6eed444132efee9c72ab582b5645d3576` (ZIP) and
`fa0489a57b790f51f3d8eea0fa2b4d816bf9a123559f9fd0da71e0ddab6521f4` (DMG).
Sites currently lists `browser.free` version 98 from
`827e7231d0a756063425387d4c635d7066fa0424`; its deployment status is
`succeeded`. A fresh browser load of the public page shows version 0.7.11 / 74.
The exact `/api/release` route remains unverified: direct web access was
unavailable and the in-app browser blocked the API URL. This is not evidence of
a site outage or of the API response contents.
The fresh read-only `gh auth status` check still reports invalid saved tokens
for both local GitHub CLI accounts. Connector access is sufficient for the
read-only audit, but it does not provide an asset-upload path; defer renewing
CLI authorization until an exact releasable candidate exists.

In the permitted macOS context, `security find-identity -v -p codesigning`
returns four valid identities, including two Developer ID Application
identities. `xcrun notarytool history --keychain-profile neantik-notary` reads
100 recent records; the newest shown are NeClip submissions. This confirms
profile access, not M154 signing or notarization; no M154 candidate was
submitted. No Xcode was installed or selected during these checks. Beta remains
globally selected; the running diagnostic Ninja process uses the existing
Xcode 27.0 process-scoped and test-only system-Xcode override. Its generated
SDK is 27.0, while the pinned official hermetic SDK is 26.5 / build `25F70`, so
this build is not release-toolchain evidence.

The same live Ninja session 85039 advanced to `21440/53999` actions as of
19:01 UTC. Its log contains no `FAILED`, `ninja: build stopped`, or compiler
error. `args.gn` still confirms arm64, `safe_browsing_mode=0`, and
`enterprise_cloud_content_analysis=true`. Neither requested test executable
has completed; do not start a competing Ninja process. The current diagnostic
tree remains non-promotable pending clean ordered source replay, complete
build/test/runtime evidence, and the normal Direct Distribution gates.

### Local regression and build checkpoint — 2026-09-27 19:05 UTC

The three focused M154 source-tooling suites passed 35/35 tests:
`test_export_chromium_154_port_input_manifest`,
`test_apply_owned_runtime_device_tuples_154`, and
`test_verify_nevision_patchset_manifest`; `git diff --check` also passed. These
tests validate the local overlay/export/verifier tooling only, not the complete
Chromium source replay or runtime. GitHub's branch endpoint still reports
`codex/neantik-workplaces` at `39e51de05c173c3f9261b894fd43f486b6429a0a`;
local HEAD `36db4e7a32882319cf6e1c49c4acd4ac59122cb7` is nine commits ahead,
with 12 modified/untracked paths. Nothing was committed or pushed. Local
`gh auth status` still reports both saved CLI tokens invalid, so an asset
upload route remains unavailable until an exact candidate is ready and the
CLI is reauthenticated.

The same Ninja session 85039 remained live and advanced to `21757/53999`
actions at 19:05 UTC. Its log still has no compiler error or Ninja failure.
The test executables remain pending on this build; no competing Ninja process
was started. Safe Browsing remains `safe_browsing_mode=0` in the inspected
diagnostic args.

### Evidence reconciliation — 2026-09-27 19:08 UTC

The top-level diagnostic status had a stale `orderedOwnedPatchReplay` count of
11, contradicting the newer port experiment. It now matches the authoritative
`port-experiment.json`: 16 groups applied, zero group failures, and 62 touched
paths in the ordered sparse replay. The status keeps the explicit limits: no
whole-tree postimage contract, complete GN graph, runtime, or release has been
qualified by that sparse replay. The active-build record was also refreshed to
`22602/53999` at 19:08 UTC. All 35 focused source-tooling regression tests
passed again after the evidence update; both JSON artifacts parse and
`git diff --check` passes. Ninja session 85039 remains the sole active build.

### Active build source identity — 2026-09-27 19:11 UTC

Read-only inspection of the exact source root used by Ninja session 85039
confirms HEAD `a654841425914cbb703a2931e07b70a83aedbafd`, 720 Git status paths,
and 268 `.rej`/`.orig` files. Its `args.gn` SHA-256 is
`f89bca0caf42fc5650717fc307584de81ec7353328b8236bc20ddf14f3df4ada`; the file
sets arm64, `safe_browsing_mode=0`, and
`enterprise_cloud_content_analysis=true`. This exact build source is still a
dirty diagnostic tree, not the clean ordered replay required for release. The
same Ninja process is live at `23226/53999`, with no logged compiler error or
Ninja failure. The source identity, reject-file count, args hash, and progress
are recorded in the M154 port experiment.


### Fresh M154 continuation — 27 September 2026, 19:38 UTC

Fresh GitHub REST output still identifies immutable `v0.7.11` / build 74 as the latest release (source `fa3b03cbe122840ea308d2ecf19004a1128a1a06`). GitHub ZIP and DMG digests remain `141ffacec0fb601a9e20fa722b348bc6eed444132efee9c72ab582b5645d3576` and `fa0489a57b790f51f3d8eea0fa2b4d816bf9a123559f9fd0da71e0ddab6521f4`. Sites reports `browser.free` version 98 from `827e7231d0a756063425387d4c635d7066fa0424`, deployment `appgdep_6ab7a6a93c0c8191bfa09f9f60a55a5d` succeeded. A permitted fresh GET of `/api/release` returned HTTP 200 / 2367 bytes, body SHA-256 `40843ee519de50550c7fa533575764865c8916de89415ec71299d411b95f7580`; it reports 0.7.11 / 74, Chromium 153.0.8010.52 below baseline 154.0.8037.58, `published-runtime-gated`, `canDownload=false`, and null ZIP/DMG URLs. The release API ZIP digest matches GitHub.

A fresh permitted macOS read-only query returned four valid code-signing identities, including two Developer ID Application identities; `neantik-notary` history access succeeded, and the 0.7.11 NeAntik ZIP and DMG submissions remain Accepted from 2026-09-24. These are existing release-contour credentials and historical evidence only; no M154 submission has been made. No Xcode was installed, removed, or globally switched. `xcode-select` remains on the pre-existing Xcode Beta 27.0 (`27A5228h`); the active disposable diagnostic Ninja process uses a process-scoped override to pre-existing `/Applications/Xcode.app` (`27A266a`).

The resumed `net_unittests` + `enterprise_archive_analyzer_unittests` Ninja build stopped at 726/29,752 after `translate_ranker_impl.cc:229` triggered `-Werror=unreachable-code`. The pinned common overlay already sets translation-ranker query/enforcement false and returns `true` before that code, preserving the same default “offer translation” behavior. Owned group 18 (`m154-remove-unreachable-translate-ranker-body.patch`, SHA-256 `e9e78dc06fa5a078fa213c2af21c84c8d3faf1f39ce7ca7189f9c2de255a6ff4`) retains the early return and removes only its dead body. The isolated `translate_ranker_impl.o` build passed. All 18 owned groups then passed ordered sparse `git apply --check` + apply on the 65 touched paths. Six paths still differ from the active diagnostic source (Safe Browsing BUILD.gn and five Blink files), so the sparse replay does not establish whole-tree equality or release readiness. Three focused Python suites pass 35/35 and `git diff --check` passes.

The full six-job test-target build is active again as Ninja session 6248 at 353/29,024 actions at 19:38 UTC. This remains a diagnostic source tree with unresolved `.rej/.orig` files, incomplete source postimages and GN dependencies, and no candidate-bound runtime, signing, notarization, Gatekeeper, hosted-byte or rollback cycle. The M154 release gate remains closed; do not distribute this diagnostic output.

### Test-build follow-up — 27 September 2026, 19:42 UTC

The next incremental test build reached Autofill and stopped on four `-Werror` unused declarations in `autofill_crowdsourcing_manager.cc`. The pinned common-overlay postimage already replaces `AutofillCrowdsourcingManager::StartRequest` with an immediate `return true`; its former `SimpleURLLoader` request body is absent, so there is no Autofill crowdsourcing network send to preserve. Owned group 19 (`m154-prune-disabled-autofill-network-helpers.patch`, SHA-256 `2ef2ef8060f538b53e1f661c7307e9a7d7620f2da80829ee0c54973e64d6549d`) removes only the unused timeout and response-header constants plus the now-unreferenced traffic-annotation and API-body helpers. It leaves the early return, callers, and network-disabled behavior unchanged. The isolated `autofill_crowdsourcing_manager.o` compile passed.

All 19 owned groups pass ordered sparse replay on 66 touched paths. Six active-source mismatches remain (one Safe Browsing BUILD.gn probe change and five later generated Apple-device-tuple postimages); whole-tree replay is still not proven. The three focused tooling suites pass 35/35 after registering group 19; JSON parsing and `git diff --check` pass. The six-job `net_unittests` + `enterprise_archive_analyzer_unittests` build has resumed as Ninja session 38350; it was live at 45/28,375 actions at 19:42 UTC. Safe Browsing stays at mode 0. This entire M154 tree and build remain diagnostic-only.


### M154 replay comparison clarification — 27 September 2026

The 19-group replay comparison was extended with the separate canonical M154 Apple tuple renderer (`apply-owned-runtime-device-tuples-154.py`) using its eight locked postimages. All eight generated files now match the active diagnostic source byte-for-byte, including the five Blink surfaces. Of the 66 paths changed by the 19 owned patch groups, only `chrome/browser/safe_browsing/BUILD.gn` still differs; that difference is temporary diagnostic GN include-check scaffolding. The full source still has other untracked reject/orig artifacts and incomplete postimage ownership, so this partial equality does not qualify a clean source replay or release candidate.


At 2026-09-27 19:49 UTC, test-target Ninja session 38350 remained live and advanced to 1309/28375 actions. No new compiler failure was reported in this interval; both test binaries remain pending. The local `gh auth status` check still reports invalid saved tokens for `AffPapa` and `mrdumay-source`; read-only GitHub connector access is intact. No login flow, commit, push, asset upload, or release mutation was attempted.

### Fresh no-loop / toolchain reconciliation — 2026-09-28 07:17 UTC

This is a new diagnostic build session, not a retry against the old output tree:
there is one active Ninja PID (46980), using
`/private/tmp/neantik-m154-clean-ordered-68-preserve-tests-20260928/src` at
Chromium commit `a654841425914cbb703a2931e07b70a83aedbafd`, output
`out/NeAntikM154OrderedReplayStable27`, and `-j6`. The source is the disposable
M154 ordered-patch overlay with 69 owned patch groups; it is not the NeAntik
manager checkout at `36db4e7a32882319cf6e1c49c4acd4ac59122cb7`. The ordered
overlay manifest SHA-256 is
`f9e9b75a02d88a2411746d863ff4634fefc4130e1c35d9d738e12bf7f7749cb7`. GN
generation and all four prior target checks passed; Safe Browsing remains mode
0. Current `args.gn` SHA-256 is
`06c5b63cdfa3e4bc915c19a2db8ceefba4391e5b23e6340b9fa604e63346967f`.

System `xcode-select` still points at Xcode Beta (`27A5228h`), unchanged. This
single build process explicitly uses installed Stable Xcode 27 (`27A266a`, SDK
27.0) via process-scoped `DEVELOPER_DIR`; `CR_XCODE_BUILD` in compiler commands
matches Stable. This avoids mixing toolchains, but Chromium's M154 release pin
is SDK 26.5 / build `25F70`, so the current build is diagnostic only. No Xcode
was installed and the global selection was not changed. Ninja had reached
`15654/49729` actions at this checkpoint; the log scan found no compiler or
Ninja failure. The full Chrome target and follow-up tests remain pending.

Fresh public read-only checks on 2026-09-28 confirm GitHub latest is immutable
`v0.7.11` / build 74 and `browser.free/api/release` still gates downloads below
the M154 security baseline. GitHub's public `codex/neantik-workplaces` ref is
`39e51de05c173c3f9261b894fd43f486b6429a0a`; local HEAD is nine commits ahead,
with 16 changed/untracked paths. Local `gh auth status` again reports invalid
saved tokens; this does not affect public GET access. No device login, release
mutation, commit, push, sign, or publish was attempted. The release gate still
fails closed for M154 because exact official toolchain/source contracts and
post-build runtime evidence are not yet qualified.

At 2026-09-28 07:59 UTC, the same Ninja PID 46980 had advanced to
`20084/49729`. A fresh scan of its append-only log found no `FAILED`, compiler
error, fatal error, or stopped-build marker. Stable Xcode 27A266a remains
process-scoped, `-j6` remains the only active Ninja, the exact args/manifest
hashes above are unchanged, and `safe_browsing_mode=0` remains set. The
machine-readable diagnostic status is refreshed at the same checkpoint. This
is still a diagnostic source/toolchain build, not a release candidate; test
targets, runtime verification, signing, notarization, Gatekeeper, and hosted
artifact checks have not started.

### Full Chrome compile midpoint — 2026-09-28 08:52 UTC

The same Ninja process/output reached `25128/49729` actions (about 50.5%). Its
log contains no failure or compiler-error marker at this checkpoint. The
~95 actions/minute measured since the prior checkpoint implies roughly 4 hours
for the remaining compile actions, with high variance by target; dedicated
unit-test targets will add work after `chrome` completes. This is not a public
release ETA. Toolchain/source qualification still blocks signing or
publication, independently of the compile result. Machine-readable state is in
`runtime/chromium-154-diagnostic-status.json`.

### Fresh release and build reconciliation — 2026-09-28 10:36 UTC

A live public GET of the GitHub API and `https://browser.free/api/release`
reconfirmed immutable release `v0.7.11` / build `74`, ZIP SHA-256
`141ffacec0fb601a9e20fa722b348bc6eed444132efee9c72ab582b5645d3576`, DMG
SHA-256 `fa0489a57b790f51f3d8eea0fa2b4d816bf9a123559f9fd0da71e0ddab6521f4`.
The site still reports Chromium `153.0.8010.52`, baseline `154.0.8037.58`,
`published-runtime-gated`, and `canDownload=false`. No release bytes changed.

The previous build stopped at action `36621/49729`: M154 navigation observer
could not include `safe_browsing_prefs.h`, removed by the no-Safe-Browsing
common overlay along with its `.cc` and GN target. Owned group70
`m154-restore-safe-browsing-prefs-plumbing` restores only the exact Chromium
upstream prefs files and original GN `static_library` definition. Its patch
SHA-256 is `51ffee29032e0f3a311d16316a230df1aa6317b54717fd9eb5ee07d3158f2bef`.
Exact reverse/apply on the group69 source and isolated common-overlay replay
passed; GN regenerated 35,012 targets, and `gn check` passed for `//chrome:chrome`,
Safe Browsing common/browser unit-test targets, and Enterprise connectors.
Generated `safe_browsing_mode`, `SAFE_BROWSING_AVAILABLE`, and
`SAFE_BROWSING_DOWNLOAD_PROTECTION` remain `0`; Enterprise Content Analysis is
still independently enabled. The former failing observer and restored prefs
object both compiled in the resumed incremental build.

Only one `-j6` Ninja build is running in the existing
`out/NeAntikM154OrderedReplayStable27` directory. At this checkpoint it had
reached approximately `1369/13107` remaining actions. This is diagnostic Stable
Xcode 27.0 (`27A266a`, SDK 27.0) selected per process; global `xcode-select`
remains Xcode Beta 27.0 (`27A5228h`). It does not meet the official hermetic
M154 SDK 26.5 / build `25F70` pin. Current `gh auth status` still reports the
saved AffPapa token invalid, but the Codex GitHub connector is authenticated
as `AffPapa` and repository reads work. The exposed fetch surface is GET-only
and does not create Releases or upload binary assets; no device OAuth was
repeated. The earlier restricted-context Keychain result was inconclusive. A
fresh read-only check in the permitted macOS context found four valid signing
identities including Developer ID Application, and the `neantik-notary` profile
was accessible with accepted submission history. No candidate was signed or
submitted to Apple. The compile, test/runtime, exact toolchain, candidate
signing/notarization, Gatekeeper, and binary-asset write path remain open; do
not publish this tree.

### Loop and toolchain reconciliation — 2026-09-28 12:08 UTC

The same diagnostic `chrome` attempt reached action `12632/13107`, then failed
at the final `NeAntik Browser Framework` ThinLTO link. The tool response was
truncated and the available scratch logs do not contain that original linker
stderr, so its cause is explicitly unresolved. A broad continuation was
stopped at `143/2243` after read-only Ninja diagnostics showed SDK/header
timestamp invalidations; this was not treated as proof that another full
rebuild was necessary. A manual direct-link probe also failed because Ninja's
ephemeral response file was absent, so it provides no evidence about the
original linker failure. No build is currently running.

The native Swift suite wrapper had a real fail-open bug: it swallowed a
nonzero compatible-Xcode resolver result in an `export` assignment, then used
the global Xcode Beta. `scripts/verify-native-swift-suite.sh` now exits 69
instead when the resolver fails or returns an empty path. Shell syntax and the
fail-closed behavior passed. The one `ProfileStoreTests` run completed 38/38
tests while global Xcode Beta was selected, including 5,000 profiles in
1.34 seconds and 10,000-profile startup in 0.15 seconds; this is not claimed
as a Stable-Xcode run. Build/test completion still requires a compatible pinned
release toolchain, capture of the exact framework-link failure, and runtime,
signing, notarization, Gatekeeper, and hosted-byte gates. The checkout remains
uncommitted; no candidate was signed or published.

Fresh follow-up at 2026-09-28 12:11 UTC corrected the earlier auth snapshot:
`gh auth status` now succeeds for active AffPapa with `repo` and `workflow`
scopes, so the repeated device-code step is no longer a blocker. Public GitHub
Release API still reports immutable `v0.7.11` / build `74`, and `browser.free`
returns HTTP 200; its API still reports Chromium `153.0.8010.52` below baseline
`154.0.8037.58` and `canDownload=false`, with the hosted ZIP SHA matching the
GitHub asset. A fresh permitted read-only check again found four valid signing
identities and 100 notary history records, latest `Accepted`. No release write,
signing, or submission was attempted.

### Full Swift suite and credential recheck — 2026-09-28 12:18 UTC

The full SwiftPM suite ran with process-scoped Xcode Beta `27A5228h`: 636
tests across 70 suites. One local STUN-listener test failed inside the
restricted sandbox with `Network.NWError error 1 - Operation not permitted`;
the same three-test suite then passed 3/3 in the permitted macOS context. The
full run's other 635 tests passed, so all 636 currently have passing evidence
across the full run plus this narrowly scoped retry. No suite-wide rerun was
needed.

Toolchain investigation confirmed Beta Swift/SDK signatures match each other;
Stable Xcode `27A266a` compiler and SDK Swift signatures do not match. The
release-specific Chromium toolchain is still separate: local `cipd auth-info`
reports `Not logged in`, and the pinned SDK 26.5 / build `25F70` bundle is not
available in the checkout or local cache. No CIPD login/download was attempted.
The full M154 diagnostic Chrome build still lacks its final framework binary
because its ThinLTO link failed; exact stderr is unavailable, and the later
wide Ninja resume was deliberately stopped after a read-only dry-run explained
the 2,097 dirty actions. Do not retry a broad build until either the pinned
toolchain is available or the exact edge's Ninja response-file/link failure is
reproduced and logged.

### Loop audit and M154 verifier progress — 2026-09-28 12:28 UTC

An independent read-only audit reconciled the Xcode/toolchain and build history.
Global `xcode-select` remains `/Applications/Xcode-beta.app/Contents/Developer`
(27A5228h); the one current diagnostic Ninja session uses the already installed
`/Applications/Xcode.app/Contents/Developer` (27A266a) only through
process-scoped `DEVELOPER_DIR`. No Xcode was installed and no global selection
changed. Both use SDK 27.0; neither satisfies the Chromium M154 hermetic SDK
26.5/build 25F70 pin. `cipd auth-info` remains `Not logged in`; no credential
flow or package download was attempted.

The previous framework ThinLTO failure had lost stderr; a bad direct-link probe
without Ninja's response file and a broad resume stopped after dry-run analysis
are not separate valid build proofs. The current single attempt #7 uses the
same output directory, `-j6 -d keeprsp`, and writes its full log to
`/private/tmp/neantik-m154-chrome-attempt7.log`; at 12:27 UTC it had reached
261/2077 actions with no failure marker. Do not start another build. If it
fails, inspect that precise edge and preserved response file before any retry.

The Swift fail-open wrapper has been fixed and the complete 636-test coverage
was already reconciled; do not rerun it absent a relevant code change. M154
source-provenance routing now selects the explicit source-contract/rebase-plan
paths and rejects release qualification while those reviewed files are absent;
its focused tests pass 27/27. The release-verifier work is still in progress.
GitHub CLI is active as AffPapa (`repo`, `workflow`); device OAuth is not a
remaining task. Public release remains v0.7.11/build 74 and the live site
remains download-gated. No candidate signing, notarization submission, release
write, commit, push, or publication has occurred.

### Fresh public, Keychain, and local SDK recheck — 2026-09-28 12:40 UTC

Fresh public GETs at 12:36 UTC confirm immutable GitHub `v0.7.11` / build 74;
ZIP and DMG SHA-256 remain
`141ffacec0fb601a9e20fa722b348bc6eed444132efee9c72ab582b5645d3576` and
`fa0489a57b790f51f3d8eea0fa2b4d816bf9a123559f9fd0da71e0ddab6521f4`.
`browser.free/api/release` returns HTTP 200 with the matching ZIP hash,
Chromium 153.0.8010.52 below baseline 154.0.8037.58, and `canDownload=false`.
Fresh `gh auth status` is active AffPapa with `repo`/`workflow` scopes. A fresh
permitted read-only Keychain check found four valid identities including
Developer ID Application; `neantik-notary` returned 100 history entries, latest
Accepted. No release mutation was performed.

The exact macOS SDK `26.5` / build `25F70` is present at
`/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`. This does not provide
the Chromium hermetic Xcode binaries package: the M154 source specifies the
`infra_internal/ios/xcode/xcode_binaries/mac-arm64` CIPD package, which is absent
locally, and `.cipd_client auth-info` reports `Not logged in`. The Chromium
hermetic-toolchain instructions state that this package is restricted to
Googlers and infrastructure bots. No login or download was attempted.
The current Chromium mac SDK declaration pins version `26.5` / build `25F70`
([official `mac_sdk.gni`](https://chromium.googlesource.com/chromium/src/build/%2B/master/config/mac/mac_sdk.gni)); the access restriction is documented in the
[official hermetic-toolchain guide](https://chromium.googlesource.com/chromium/src/%2Bshow/8742c9f6bd62c95f6837e2db7d2dd17085dd051c/build/docs/mac_hermetic_toolchain.md).

The M154 diagnostic-input exporter completed against the current ordered source
and emitted `/private/tmp/neantik-current-m154-input-manifest.json`; it binds
the source commit/tree, patch/tool inputs, `args.gn`, and `safe_browsing_mode=0`
but explicitly reports `diagnostic-source-only` and `releaseReady=false`. The
full manifest is not a source-to-binary release proof. Attempt #7 is still the
only build; at 12:40 UTC its log reached 822/2077 with no failure marker. Keep
it at `-j6`; do not launch a duplicate.

### Current M154 build and final live snapshot — 2026-09-28 12:46 UTC

The public GitHub `/releases/latest` endpoint still returns `v0.7.11` (four
assets, published 2026-09-24); the exact release assets and the site API hash
were rechecked above. `gh auth status` is active as AffPapa; Developer ID and
`neantik-notary` were freshly read at 12:36 UTC. No OAuth, signing, notarization
submission, upload, or publication was repeated.

In the active M154 output, GN's generated
`gen/components/safe_browsing/buildflags.h` explicitly sets
`FULL_SAFE_BROWSING`, `SAFE_BROWSING_AVAILABLE`, and
`SAFE_BROWSING_DOWNLOAD_PROTECTION` to 0; `args.gn` retains
`safe_browsing_mode=0` and separately sets
`enterprise_cloud_content_analysis=true`. This records the exact mode-0
boundary; it does not claim standard Safe Browsing protections are enabled.

Attempt #7 terminated at action 1603/2077: final framework ThinLTO link reported
undefined screen_ai::ScreenAIInstallState::GetInstance() because the service is
disabled in GN. The latest audit below supersedes this snapshot.


### Loop audit and bounded M154 retry — 2026-09-28 13:01 UTC

The Xcode identities were separate: global selection remains Xcode Beta
27A5228h; the failed build and its one retry used installed Stable 27A266a only
through process-scoped DEVELOPER_DIR. Both used diagnostic SDK 27.0. No Xcode
install or global selection change is needed. GitHub CLI authentication remains
active; do not repeat device authorization.

Attempt #7 was terminal, not still running. Its final link failure came from an
unguarded ScreenAI sandbox branch while ENABLE_SCREEN_AI_SERVICE=0. The narrow
patch m154-guard-disabled-screen-ai-sandbox-setup.patch (SHA-256
613419c7bf824bd7775fb14c5265e56fb0f841ac59931f2c36779305965687ef) passed
clean-base apply-check and reverse-apply against the group70 diagnostic source.
The affected object compiled, then one same-output incremental chrome build
completed all 476 actions. The linked arm64 framework no longer has an undefined
ScreenAIInstallState::GetInstance symbol. This is diagnostic evidence only. Group71 was sequentially applied after its
preimage matched the prior group70 whole-tree inventory; the inventory was
refreshed for that one path and the 71-group M154 source-input exporter passed.

Release remains closed. Chromium M154 pins hermetic SDK 26.5/build 25F70; the
local SDK is only the CLT copy, and the required internal CIPD Xcode bundle is
not available in this environment. The shell LaunchServices command returned OSStatus -10827 in the Codex
execution context, but the exact attempt8 app then opened through the native GUI.
Its local chrome://version page showed Chromium 154.0.8037.58, arm64, the expected
source commit and executable path. The smoke used the existing Chromium Default
profile and opened no external site; the app was quit afterward. This proves only
GUI startup/version display, not an isolated-profile, network, recovery,
fingerprint, or A→B→A runtime cycle. A prior direct-headless attempt also failed
during TransformProcessType registration. No signed candidate, notarized artifact,
upload, or publication was produced. Safe Browsing mode 0 remains unchanged.

### Evidence reconciliation — 2026-09-28 13:16 UTC

A fresh GitHub REST read and browser.free homepage/API read reconfirmed the same
immutable `v0.7.11` / build `74` release, four GitHub assets, matching ZIP/DMG
SHA-256 values, and `canDownload=false` while the public Chromium runtime is
153.0.8010.52 (required baseline 154.0.8037.58). No release or OAuth action was
needed.

The latest M154 status is now canonical: attempt #8 and its 476/476 incremental
`chrome` build are complete, and the exact attempt8 app passed a limited native
GUI startup/version smoke on `chrome://version`. Earlier `-10827` text is kept
as a shell-only probe result, not a current app-launch failure. Stale blocker
fields were corrected; historical attempts remain history. No build was
repeated. The smoke does not close isolated-profile, network, recovery,
fingerprint, keyboard, or A→B→A gates, and the app was not release-qualified.


The same read-only pass also closed a selector safety gap: the packaged-runtime
verifier now routes M152 and M153 evidence explicitly and rejects M154 instead
of falling back to M152; unknown versions fail closed. Its focused suite passed
10/10. Current local `gh auth status` reports invalid CLI credentials even
though the connected GitHub API remains usable for reads. The latest shell
Keychain check was context-limited (zero identities and a notarytool parameter
error); earlier permitted macOS evidence showed valid identities/profile access.
Treat current signing access as unconfirmed and recheck in the permitted macOS
login context before signing. No OAuth, signing, build, or publication was
performed.


### Release evidence selection guard — 2026-09-28 13:24 UTC

The Direct release launcher now reads the Chromium version embedded in the exact
integrated source app and compares it with both the selected candidate lock and
source provenance before caching them. It refuses implicit M154 evidence, and
legacy discovery skips M152/M153 evidence whose version does not match the app.
The packaged report verifier also allows only the exact reviewed M152 and M153
versions; M154 and unreviewed patch levels fail closed. This prevents wasting a
release attempt on stale evidence and does not qualify or produce an M154 build.
The complete `scripts/tests` suite passed 725 tests (one skipped); `zsh -n`,
Python compilation, JSON parsing, and `git diff --check` passed.


### Signing-context recheck — 2026-09-28 13:27 UTC

A fresh permitted macOS-context read-only check found four valid signing
identities, including two Developer ID Application identities. The
`neantik-notary` profile was readable and its latest history entry was Accepted
(100 entries returned). This supersedes the earlier shell-context Keychain
parameter error; that error was a context limitation, not missing credentials.
It does not prove that a new candidate has passed signing, notarization,
stapling, or Gatekeeper. Local `gh auth status` remains invalid, so CLI
authentication will be needed before an eventual upload; no device OAuth was
started.


### Loop audit and M154 test-target reconciliation — 2026-09-28 14:32 UTC

The recent work did not repeat the diagnostic `chrome` build: attempt8 previously
completed its 476-action incremental target and passed only a limited
`chrome://version` GUI smoke. The latest work was a separate focused test-target
build on the same diagnostic source. Groups72/73 passed ordered apply checks and
the source exporter passed; this is not release qualification.

Test outcomes are now reconciled in `runtime/chromium-154-diagnostic-status.json`:
`enterprise_archive_analyzer_unittests` passed 51/51. `net_unittests` linked, but
the attempted `BlocksSubstitutedSafeBrowsingUploadHost` filter matched no test,
so it supplies no test coverage. The Safe Browsing test target stopped at a
test-only reference to `prefs::kSafeBrowsingEnhanced`, which is absent because
`SAFE_BROWSING_AVAILABLE=0` under the retained mode-0 configuration; no tests
from that target ran. The earlier `SetSafeBrowsingConfig` test-helper error was
fixed by group72 and is superseded. Production Safe Browsing flags and mode were
not changed.

Toolchain identities remain distinct: Beta 27A5228h is globally selected;
Stable 27A266a was used only via process-scoped `DEVELOPER_DIR`. Both are SDK
27.0. The missing Chromium-pinned hermetic SDK26.5/build25F70 toolchain remains
the qualification gate; installing another Xcode or repeating device OAuth is
not indicated. Public release remains v0.7.11/build74 on M153 with downloads
disabled. No signing, notarization, commit, push, upload, or publication occurred.
Do not repeat the diagnostic `chrome` build or unchanged focused test command;
next work is exact toolchain/source qualification, mode-0-compatible focused test
coverage, then the remaining runtime matrix and candidate release gates.


### Credential and loop-safety correction — 2026-09-28 14:32 UTC

One more context check prevents a false inference: local `gh auth status` now
reports invalid saved CLI credentials for both stored accounts. That is separate
from the connected GitHub API/app path used for read checks; do not repeat device
OAuth at this stage. CLI publication will need a valid CLI credential only when
an exact release candidate is ready. The sandboxed shell Keychain probe returned
zero identities and notarytool did not produce JSON, so these results do not
show that signing credentials are missing. The last successful permitted
macOS-context check found four identities (two Developer ID Application) and an
Accepted `neantik-notary` history entry; repeat only in that context before
signing. The expected local CIPD executable was absent, so no package auth or
download was attempted. These checks changed no credentials or machine settings.


### Hermetic toolchain and current runtime scope — 2026-09-28 14:39 UTC

Corrected the earlier `cipd` path assumption. A read-only search found the client
at `/private/tmp/neantik-depot-tools/.cipd_client` (SHA-256
`4ac2fa37f23486d249a2d71ff5084b6207c00cfa55928dad577fe99f0376ab71`); its
`auth-info` says `Not logged in`. It is a separate Google/CIPD auth domain from
GitHub. No login, package fetch, or installation was attempted. The M154 pinned
hermetic Xcode package is absent from the checked local caches. SDK 26.5 is
present in Command Line Tools and resolves only with process-scoped
`DEVELOPER_DIR=/Library/Developer/CommandLineTools`; that CLT toolchain does not
satisfy the pinned hermetic-build contract. The installed Xcode Beta and Stable
remain on SDK27.

The existing M154 app is a bare Chromium diagnostic bundle, not a current
integrated NeAntik manager/candidate. Its only GUI evidence is startup and
`chrome://version`; the earlier smoke touched the existing Default profile and
proved no isolation or A→B→A behavior. Groups72/73 only alter test-support code,
so they do not change that browser binary's runtime. Repeating that smoke would
not close a release gate. Do not launch it against user data again. An integrated
M154 manager/candidate plus isolated test profiles and the authorized runtime
matrix remain necessary before signing or release.


### Loop and stale-count correction — 2026-09-28 14:53 UTC

The 13:04 `currentTurnPatchFollowup` / attempt8 records above are historical
snapshots at group71. The newer test-target record and port ledger are current:
groups74/75 are test-only, bringing the ordered diagnostic ledger to 75. A
follow-up check found and fixed one actual stale test fixture that still
hardcoded 71; the focused exporter and patchset-manifest suites now pass 33/33.
No diagnostic `chrome` rebuild, repeat GUI smoke, Xcode install/switch, or
GitHub OAuth was performed. Global selection is still Xcode Beta 27A5228h;
Stable 27A266a was used process-scoped for the earlier SDK27 diagnostic work.

The remaining external toolchain gate is Chromium's pinned hermetic CIPD Xcode
bundle (SDK 26.5/build 25F70). The discovered CIPD client reports `Not logged
in`; this is separate from GitHub, whose connected app/API path remains usable
for reads even though local `gh` credentials are invalid. GitHub CLI access
will matter only after a release candidate is qualified. No further compile
churn is justified on the SDK27 diagnostic tree. Keep public v0.7.11/build74
and its download gate untouched until a clean qualified M154 source/build,
integrated manager runtime matrix, exact-candidate signing/notarization/Gatekeeper,
hosted byte verification, and rollback all pass.

## Current goal checkpoint — 29 September 2026

Latest broad Stable Mac remains Chrome 154 `154.0.8037.58`; Chrome 155 is only
Early Stable for a small percentage. The local M154 port is still diagnostic.
The official macOS packaging source is identified, and upstream replay is
complete: all 109 common and 20 macOS patches applied to a clean `.58` worktree
with exact pinned dependencies. The retained full-DEPS source has a 240-entry
revision lock and ordered 75-group NeAntik replay. A fresh diagnostic source
input manifest was exported on 29 September, but no release-qualified source
contract exists. The hermetic SDK 26.5/build 25F70 package is unavailable to
this context; Stable Xcode 27 has not been qualified as the release toolchain.
Existing
release verifiers correctly fail closed. Local `gh auth status` reports
invalid saved tokens; connector reads do not enable asset upload. Signing and
notary access is available in the permitted macOS context, but no new
integrated candidate exists. Do not repeat prior diagnostic attempt8, GUI
smoke, or OAuth. Keep v0.7.11 as rollback.

Verification on this checkout: Python `scripts/tests` passed 725 tests with
one skip; full native Swift passed 636 tests across 70 suites; the focused
loopback suite passed 3/3 in the permitted macOS context; and `git diff --check`
passed. The earlier Swift failure was sandbox `Operation not permitted` on a
loopback bind, not a product test failure.

### M154 upstream-source discovery and replay correction — 29 September 2026

Official upstream now publishes the matching macOS packaging source set at
`ungoogled-chromium-macos` tag `154.0.8037.57-1.1`, commit
`3241dc9cacee393621d277ec936376072f0cb3c5`, pinning common source
`800d0bb5078472e4442c1fd73373172754a60939`. Chromium `.58` is a direct child
of `.57` and changes only `chrome/VERSION`; upstream `validate_config.py`
passed. This resolves discovery of a candidate upstream source pair, not the
NeAntik source contract or runtime qualification. See the
[upstream macOS release](https://github.com/ungoogled-software/ungoogled-chromium-macos/releases/tag/154.0.8037.57-1.1).

The first throwaway replay attempts had an extra `src/` path and a checkout
hydration race; these were operator errors, not source or DEPS blockers. After
awaiting checkout completion, a clean `.58` worktree with exact V8, NASM,
DevTools, and search-engine pins applied all 109 common and 20 macOS patches
successfully. The separate pinned full-DEPS source and owned replay are listed
in `runtime/nevision-patches/ports/chromium-154.0.8037.58/port-experiment.json`.
The diagnostic exporter succeeded against the 75-group tree with tracked-diff
SHA-256 `6f78e05a72a49ad8ee7660897fbec4e7592fd8d5c8b92751436a18ebc56a46be`;
it recorded 20 untracked inputs and `releaseReady=false`. One temporary Safe
Browsing `BUILD.gn` scaffold remains outside the owned postimage inventory.
Do not repeat source replay. Next review that mismatch, bind Stable Xcode 27,
SDK and Metal as the release toolchain or obtain the pinned CIPD package, then
finish the M154 release contract and remaining build/runtime/release gates.
No candidate signing, notarization, GitHub upload, or site publication occurred.


### M154 no-loop correction — 2026-09-29

The earlier temporary Safe Browsing `if(false)` scaffold is removed from the active diagnostic source. Its clean expected postimage is Chromium 154.0.8037.58 HEAD plus owned group16; this regenerated successfully with GN (35,018 targets). The former group69 `m154-initialize-enterprise-safe-browsing-mode0-target` patch overwrote pre-existing non-empty `public`, `sources`, and `deps` arrays and failed clean GN generation. It has been withdrawn from the active patch sequence, its patch file/hash remain as superseded evidence in `port-experiment.json`, and it must not be replayed. Active group count is 75; the SDKROOT path fix is group75.

The Ninja graph that included the scaffold was intentionally stopped before producing an app and is not build evidence. Resume from the corrected graph. This still uses diagnostic Stable Xcode27/SDK27, not the pinned hermetic release toolchain; release gates remain closed.

### M154 continuation — 29 September 2026

The corrected Safe Browsing graph generated, and the M154 input exporter was
rerun against the active source. It reproduced tracked-diff SHA-256
`37585aba78a81eab1fbd8de0ce038b744f533c75205e274f626ab8592edb110c`, 20
untracked inputs, and `releaseReady=false`. A later full Ninja continuation in
`out/NeAntikM154OrderedReplayStable27` was stopped at 1,028/33,585 actions
because it still used diagnostic Xcode 27/SDK 27; do not resume it as a release
build. Existing `chrome` target completion and GUI smoke remain diagnostic-only.

The generic patchset verifier defaults to Chromium 152's `series.json`; its
successful default run is not M154 evidence. Use the M154 port-specific exporter
and group ledger, and never infer M154 readiness from the M152 `release-ready`
result. The pinned hermetic CIPD Xcode SDK 26.5/build 25F70 remains unavailable
in the recorded environment (`cipd auth-info`: not logged in); this is separate
from GitHub access. A fresh read-only release review confirmed GitHub
v0.7.11/build74 remains the rollback. It could read the live Sites listing,
but could not freshly fetch `/api/release`, so that endpoint remains unverified.
No source was signed, notarized, uploaded, or published in this continuation.

### Correction — M154 macOS packaging source (30 September 2026)

The 27 September snapshot above is historical: it reported no M154 macOS ref.
A later GitHub release check confirmed upstream tag
`154.0.8037.57-1.1` at commit
`3241dc9cacee393621d277ec936376072f0cb3c5`. This establishes that an upstream
M154 macOS packaging source exists; it does not qualify a NeAntik source replay.
The exact tag tree and series hashes still need to be bound into a reviewed
M154 contract, and the active postimage manifest currently differs from its
source tree. Keep all build and publication gates closed until those checks pass.

### M154 macOS packaging pin and ordered applicability check (30 September 2026)

The upstream macOS tag `154.0.8037.57-1.1` is now pinned by commit
`3241dc9cacee393621d277ec936376072f0cb3c5`, tree
`ef5ef849ed78edb7d8c07773df6bbb6753efe9ea`, common submodule
`800d0bb5078472e4442c1fd73373172754a60939`, and the 20-entry `patches/series`
(SHA-256 `f432ba4b0188b9e4dd4bbe9e1d21760f76048c70df69e70b2d2881ede6378510`).
All 20 patches applied sequentially to an isolated copy of their 58 touched
files from the M154 `.58` + common-overlay source, with no rejects. This is a
patch-applicability result only. The complete downstream source still has 23
postimage mismatches, including five unregistered test includes and one
unregistered Safe Browsing prefs removal; no M154 source contract or qualified
build/runtime/release follows from the applicability check.

## 8 октября: доступность опубликованных файлов и MCP

Browser.free Sites121 (source009d80e8fc193943d00b21ec73e440cf84ef8f87) сохраняет DownloadZIP/DMG для настоящего immutable0.7.23 при незавершённой квалификации нового runtime. canDownload отражает проверенный опубликованный артефакт; canPublishNewRelease отдельно отражает runtime/security/Direct readiness. Не менять latestRelease на исходники кандидата.

В manager-кандидате0.7.24 новые MCPconfigs включают --allow-profile-management; дополнительная опция только просмотра сохраняет 6tools и отсутствие флага. Старые клиенты не получают новые права автоматически. Полное текущее управление имеет17tools/3prompts, не означает произвольныйDOM/JS/shell или доступ к BrowserData. Изолированный Stable155.0.8059.40 port в работе; signing/notary нового runtime пока не квалифицированы.
