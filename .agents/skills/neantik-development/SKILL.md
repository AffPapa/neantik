---
name: neantik-development
description: Implement substantive NeAntik manager/workflow changes with scoped checks and shared caches. Skip small prose fixes; read-only runtime research uses the runtime audit skill.
---

# NeAntik development

Use the current checkout and nearest AGENTS. For continuation, read the small
CURRENT linked by the parent workspace's PROJECT_CONTEXT_INDEX. Release
manifests identify published bytes; a historical plan is not current status.

## Choose the work

Define the changed surface and observable acceptance. Read only its source,
contract and relevant receipt. Use at most 2–3 independent read-only agents
when requested; keep edits, integration and publication with the parent.

Run `python3 -B scripts/plan-manager-checks.py --base HEAD` after a change, or
repeat `--path` for a proposed change. It recommends batched Swift/Python
checks and additional native gates. Review dependencies the map cannot know.
Unknown/shared inputs select full regression. Planning never means PASS.
Explicitly reviewed shared Swift paths keep full Swift but select only
their Python readers; unknown inputs still require both full sets. `--base`
can recognize a version-only Info.plist diff from actual before/after values;
`--path` alone cannot. Native, version-floor and delivery gates stay separate.

## Execute

- Before a protected-main synchronization, read its exact required check contexts once and compare them with workflow job names. Preserve genuine CodeQL language analysis and stable shard context names; never replace required security scans with synthetic status/aggregate success or weaken branch protection.
- Ordinary CI must exclude only explicit wholly opt-in fixture suites, retain mixed/pure unit controls and reject skipped-only results. Validate fixture gates against the actual declared test type (not an assumed @Suite file boundary). Size job budgets from measured build plus test duration; keep per-test progress so a timeout is diagnosable without a blind retry.
- When independent CI lanes are already running, collect their remaining diagnostic results before pushing one repair batch. Do not cancel a failed run while other lanes can still reveal distinct failures; a record/harness failure is separate from product qualification.
- For a post-publication release record, keep the full `assets` inventory separate from the exact ZIP/DMG `artifacts` pair, copy their published checksum sidecars into `releases/`, and run `verify-open-source-tree.py` plus `verify-mcp-documentation.py` before pushing. A record-format failure never requires rebuilding qualified app bytes.
- Keep CURRENT compact: public baseline with observation date, one private or
  production candidate, last consumed attempt, reusable receipts, open gates
  and one next action. Archive prior expanded state byte-for-byte before
  compaction. Version/build, QA SHA and Sites version are distinct identities.
  Update candidate receipt, run plan and CURRENT when an attempt ends, including
  failure and cleanup; do not leave an already-used authorization as pending.
- Use one candidate receipt to generate QA identities; never adapt scripts by
  global string replacement or hand-copy hashes. For existing Swift/Python QA
  wrappers run `scripts/qa-candidate-binding.py --candidate RECEIPT --run-plan
  PLAN` before notarization/launch. It is a non-authoritative declaration lint,
  not a byte/hash/signature check; the real launcher's exact-byte gates remain
  mandatory. Retain failed harnesses unchanged as
  evidence; prepare corrected wrappers only for the next candidate.
- Keep manager RPATH sanitation before host packaging and save failed tool
  stdout/stderr in owner-only diagnostics. Before another Apple/native attempt
  inspect the host's transitive dependency closure, including Swift overlays;
  direct `otool -L` alone can miss system WebKit via libswiftWebKit. Never
  relax runtime-image uniqueness to hide a mixed owned/system engine.
- Before a recipient WebKit build, derive the complete target set from the
  staging manifest, including `libWebKitSwift.dylib` and the XPC executables.
  Pin feature flags before compiling; a late flag change can rebuild most of
  the graph. Check the staged transitive system-WebKit closure before signing.
- Before signing a rebuilt owned WebKit, run
  `scripts/check-owned-webkit-xpc-launcher.py` against the patched source and
  staged Frameworks. The compiled `WebKit` image must select the same owned
  Networking XPC name as the bundled service. On SDK 27, the staged
  JavaScriptCore image must also contain Mach exception handlers: the old
  `mach_exc.defs` feature probe silently disabled them and WebContent crashed
  before page load. These are compiled-image checks; source-only review missed
  both failures. Include
  the launcher change in the combined source patch and replay it from pinned
  upstream HEAD. After two identical startup timeouts, inspect launchd's exact
  service lookup before another archive or native retry.
- For a native SwiftPM build, resolve that invocation's actual binary directory
  with `swift build --show-bin-path` using the same scratch, configuration and
  module-cache environment. SwiftPM has produced fresh binaries under both
  `out/Products/Release` and `arm64-apple-macosx/release` on this Mac; neither
  path is authoritative across invocations. Check the selected file's mtime
  and hash, then require a byte-for-byte match with the staged executable
  before signing. Record both paths and the input SHA in the candidate receipt.
- The standalone WebKit host target compiles `DerivedSources/NeAntikWebKitHost`,
  not `Sources/NeAntik` directly. Before each changed-host build, run
  `scripts/build-webkit-standalone-host.py --prepare-only`, then compare the
  hashes of the relevant generated copies with their source files. A successful
  host build against stale derived files does not include the Swift source fix.
- Apply the actual user authorization and tool policy, not an invented blanket
  per-hash permission rule. Exact-hash or one-shot approvals remain bounded;
  broader valid authorization persists unless action/scope/risk changes or a
  tool explicitly requires confirmation. Batch the complete planned phase.
- For Dev WebKit QA copied from an earlier app, set
  `NeAntikDevelopmentFixtureRoot` to the new owner-only root before signing.
  Freeze the signed app and ZIP, then run `launch-owned-webkit-qa` with
  `--check-only` against the exact stage receipt and ZIP SHA before Apple
  submission. This catches a stale root pin without consuming a native attempt
  or an Apple notarization. Never repair a root pin inside an accepted archive.
- Before a costly operation, record in CURRENT: changed surface, observable
  acceptance, existing receipt, and a concrete reason if repeating it. Check
  declared paths/suite names and required execution capabilities first. A
  permission denial is setup, not a product defect or proof of missing account
  rights. Sandbox Keychain/Code Signing queries may silently report zero
  identities or false signature failures; when that contradicts Keychain Access
  or a preserved signed app, make one exact read-only invocation with
  `sandbox_permissions=require_escalated` before concluding a key is missing,
  changing signing inputs, or rebuilding. Reuse the working route; diagnose
  before another login.
- After a version/build bump, add its explicitly unqualified CHANGELOG entry
  and run `verify-mcp-documentation.py` before full regression. Missing release
  metadata is a fast preflight failure, not a reason to spend another full run.
- For user-facing capability claims, compare the text against the exact runtime
  gate and manager behavior, not just configuration/API code. Distinguish saved
  metadata, configured code, and a measured route. Add a regression guard when
  a stale claim could cause users to rely on a disabled or unqualified feature.
- For native QA, run `python3 -B scripts/native-qa-readiness.py --check` in
  the authorized macOS context before enrollment/launch. Unknown is not normal;
  kernel pressure, not free-memory percentage, determines readiness. Exit75/78
  means defer the launch, not repeat it or override manager admission. A normal
  snapshot only permits an attempt; it is never a native/release PASS.
  If the report includes `observerFailures.* = permission_denied`, classify it
  as sandbox/setup: make one exact read-only readiness invocation via
  `exec_command` with `sandbox_permissions=require_escalated`, then reuse that
  output for the planned phase. Do not ask the user to run `sysctl` in Terminal
  and do not use `memory_pressure` (it applies pressure; it does not observe it).
  If escalation is rejected, preserve `unknown` and continue source-only work.
  Never weaken the gate or keep retrying the same denied observer.
- Batch native QA per frozen candidate: before admission, list every eligible
  scenario and cleanup step in one run plan, then execute the changed-surface
  checks together under that admission. Do not split one planned phase into
  repeated permission requests per scenario. If readiness is unknown or
  refused, defer the entire native phase and continue source-only work; ask
  again only after a fresh environmental change makes admission eligible.
  Never broaden the approved scope or bypass a refusal to save time.
- A frozen candidate stays frozen while its delivery gate is open. Independent
  work during an external wait must not replace its bytes or restart finished
  stages. Give the pending gate priority when its concrete blocker changes.
- Before changing a build/release checker, inspect its `ownedInputs` pins and
  callers. Rebind only an explicitly unbuilt source contract to changed input;
  preserve the prior hash and negative stale-pin control. Never rewrite a
  historical or binary-bound contract to make a check pass.
- For an owned WebKit runtime, bind every signing/RPATH receipt to the exact
  `Frameworks` tree hash. Enumerate every regular Mach-O, including copied
  nested dylibs; a count of signed top-level bundles is not complete coverage.
  Relocate the exact unsigned candidate before signing; results from a separate
  research copy do not transfer. Inspect the embedded XPC entitlement payloads
  with `codesign` after signing and reject invalid blobs, `get-task-allow`, or
  `disable-library-validation`; source-generated entitlement files alone do
  not prove what the signature contains.
- Plan native QA setup, actions, evidence and cleanup before enrollment/launch.
  Reuse an authorized live authority for its exact app/private manifest until
  consumed or retired. A fixture retry alone does not require a new authority.
  Do not run an unrelated full audit solely to retire a key; record pending
  cleanup when no qualified narrow operation exists.
- For WebKit child-startup diagnosis, keep the bounded, QA-only diagnostic pipe
  open through NetworkProcess ownership, route enrollment/activation and the
  final ready frame. Draining only after bootstrap loses late failure stages;
  test both the complete stage sequence and timeout/closed-pipe outcomes. Do
  not enable this channel in production builds.
- Treat a QA profile seed as immutable input. A browser launch may rewrite
  `profiles.json`; make the next isolated root from the preserved seed, not
  from a post-run store. Pin both the resolved canonical root and its exact
  profile hash, then run the launcher’s inert check-only mode before admission.
- Before notarizing or launching a QA bundle, inspect its embedded
  `NeAntikDevelopmentFixtureRoot`. If present, require it to equal the pinned
  temporary root; a launch-time `NSWorkspace.OpenConfiguration.environment`
  override alone is not sufficient evidence that the app used that root. At
  first window, compare only the expected fixture profile count/markers. If
  they differ, do not select a row or launch a profile; terminate only the
  exact QA PID and classify the run as an isolation/setup failure.
- For an HTTP WebKit proxy fixture, inspect the **nested signed host**
  `Info.plist` inside the frozen archive before Apple upload. Its Dev-only ATS
  exceptions must cover exactly **all** synthetic QA hostnames used by the
  fixture, including subresources on a second origin;
  the production host must have no QA exception. WKNavigation error `-1022`
  means ATS rejected the page before proxy selection, so zero broker traffic
  in that run says nothing about the proxy selector. Classify it as a harness
  failure and fix the package before another native test.
- For HTTPS QA, keep WebKit trust-delegate result, TLS server handshake result,
  and HTTP page response as three separate observations. A successful
  `SecTrustEvaluateWithError` plus `.useCredential` does not prove the
  NetworkProcess completed TLS. The fixture's aggregate `refused` counter
  also covers timeout and peer TLS errors; use the dedicated handshake
  counters and closed-vocabulary QA stage before changing the network route.
  Inspect the **signed nested Dev host** ATS exceptions against the exact
  synthetic HTTPS hostname in the frozen fixture, as well as its trust scope.
  Apple's ATS can still reject a test CA after the delegate accepts it;
  production hosts must not inherit any QA exception.
  Once an archive has produced a bounded failure and been cleaned, diagnose
  that boundary offline before building/notarizing another one.
- A pinned fixture root must also satisfy the app's actual
  `NeAntikApplicationEnvironment.applicationSupportRoot` contract before
  notarization: one direct child of `/private/tmp` (or its `/tmp` alias), with
  a safe `neantik-*` basename. A nested root such as
  `/private/tmp/neantik-run/qa-root` is rejected by the app and silently falls
  back to the normal Dev Application Support directory. Require the launcher,
  embedded Info.plist value, and immutable profile seed to resolve to that
  accepted single-level path; the inert preflight must check this contract.
  Never rely only on Info.plist/environment equality.
- `test-manager-fast.py --suite NameTests` (repeat suites) executes tests using
  shared project caches, jobs2 and serial execution. Its lease is shared with
  `Develop-NeAntik.command`. Use one `--all` for integration of manager/shared
  dependency changes or a new app candidate. Standalone harness/prose changes
  use their relevant contracts; unknown/shared inputs remain full regression.
- UI work uses the canonical isolated Dev bundle and disposable fixture.
  A build is not native behavior. Bind GUI checks to its actual app/PID/root;
  after quit verify exit rather than rediscovering/relaunching the app. A CUA
  `getAXState()` on a bound app after ⌘Q may reopen that app; verify the exact
  process path with a read-only process check instead.
  For owned WebKit qualification, inspect the persisted test profile before
  launch and require `engine=webkit` plus
  `webKitRuntimeGeneration=isolatedV1`; profile creation defaults to `.system`.
  After launch, bind the signed host and Networking child to the exact app,
  profile root and expected code identity. A WebKit window title, manager label,
  or manager-app launch alone proves only the system-WebKit preview unless those
  child processes are independently verified.
  After every final host signing/re-seal, run
  `scripts/verify-webkit-host-pin.py --refresh-pin APP` to update only the
  manager plist; then shallow-sign the manager and run the verifier again.
  Do not deep-force-sign nested code after sealing pins. Keep its negative
  stale-pin control in the pre-notary gate.
  A shared bundle ID can retarget an ordinary instance. On reselect, inspect AX
  without emitting it and require the owned fixture markers plus live PID/root
  before any action. On mismatch stop UI actions; clean up only owned processes.
  For production-ID QA, prefer PID-bound native/CLI controls. CUA getApp(path)
  can activate an ordinary instance before a marker check; use a unique QA ID.
- Preserve execution receipts before parsing. Classify a failure as product,
  harness, setup or environment; diagnose two identical failures before retry.
  Fix analysis offline on retained traces when browser inputs did not change.
- For real saved-proxy inventory, a TCP open, curl timeout, or missing MCP
  response is not evidence that a paid subscription expired. The MCP manager
  serializes tool calls; a blocked Keychain lookup, file lock, child process or
  output pipe can stall the queue after the normal probe budget. Keep completed
  per-profile observations, identify the next stuck phase with nonsecret
  timings, and resume remaining profiles in bounded isolated processes only
  when native resource admission permits. Never log endpoints or credentials,
  and never delete a user proxy from a timeout alone.
- System Extensions are OS-managed: never chmod/chown/remove their staging
  files, edit the registry, disable SIP or enable developer mode to fix QA.
  Use documented activation/replacement/deactivation or Finder removal of
  the containing app. Resolve the actual registered container/file identity
  before cleanup: renaming it into a rollback folder does not unregister it.
  Keep the registered container at its canonical location until OS teardown;
  preserve rollback as a separate copy/archive. Verify kernel state afterward:
  disabled, terminated-awaiting-reboot and uninstalled are different results.
  A required reboot is an external gate; never restart the user's Mac yourself.
  Reboot invalidates prior monotonic-clock bindings, not signed-byte checks.
  Before any administrator handoff, collect actual read-only preconditions and
  test the full helper path with the exact interpreter, including rollback.
  Synthetic ownership/signature checks do not prove OS permission to mutate.
- Local full Python contracts include owned loopback listeners and own-PID
  `/bin/ps`. Establish those capabilities before the expensive run; use the
  already authorized QA execution environment. Sandbox denial is a setup
  failure: rerun only affected modules there, retain the original failure and
  never report that first invocation as an all-green run.
- Pure compilation/linking that does not execute the app/probe is build-only
  preparation, not native QA. Do not block this preparation solely by applying
  the launch gate to it. Keep one native build, jobs2, prior outputs/rollback,
  and an unqualified status; real execution still requires admission.
- Resource admission applies to app/runtime/enrollment/headed/CoreText QA,
  not reviewed model/filesystem unit tests. Owned shell-stub tests inject
  deterministic resource state and retain an explicit pressure-refusal control;
  real browser fixtures keep production admission. Do not bypass a native gate
  by calling the fixture a unit test.
- Keep ordinary CI separate from opt-in native fixtures. The clean CI shards
  share a cache within each job and execute each selected suite in a separate
  process. Nonzero exits and zero tests stop the shard.

- When excluding derived profile data from backups, cover the actual restore
  transaction with that data still present in the old live tree. Verify normal
  commit, rollback before the decision and recovery after the decision. Keep
  complete old-tree identity/entry/budget checks; archive-only round trips do
  not cover internal retention and recovery validation.

## Deliver

Record source/artifact inputs, result, evidence pointer, limitation and next
action. Keep detailed logs private and summaries small. Reuse a passed gate
only for matching inputs, harness and environment. Changed signed/hosted bytes
need their own checks; source-only tooling does not require a new app release.

For secret scans, bind the receipt to the exact target hash and scan settings.
Treat findings as unresolved until triaged, and record skipped files/archive
depth as coverage limits. Full redaction may replace every matched value with
the same marker: never infer secret uniqueness, length, or equality from that
marker. Keep raw reports private; retain only safe aggregate evidence.

For artifact provenance, compute SHA-256 from the exact file in the command or
script that writes the receipt; do not hand-transcribe or copy it from memory.
Cross-check size and any available vendor checksum/signature. If a historical
receipt has a transcription error, preserve it and add a dated correction that
names the superseding evidence.

For release, read `docs/DEVELOPMENT_WORKFLOW.md`'s release section and the
existing Direct pipeline. Publish one finished feature slice with its exact
candidate; retain prior assets and rollback. Sites and app source are separate
lanes. Preserve secrets, real data, certificate and runtime unless the task
requires an authorized change. Do not create a token because another auth
route failed.
- Determine the current public release from GitHub's Releases API, not a potentially cached rendered `/releases/latest` page. Reconcile it with the exact Sites saved version and successful production deployment before claiming the site or download is stale; retain the observed discrepancy in a small receipt.

- Engine successor update records own their version, paths, Mach-O set, report
  schema and official source/security review; do not relabel an older tuple.
  Freeze the qualified signed runtime and report before manager compilation;
  reuse those exact bytes for receipt/package changes instead of re-signing.
