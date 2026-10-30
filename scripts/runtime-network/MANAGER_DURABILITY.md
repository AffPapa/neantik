# Delayed close and fresh Chromium data

Development fixture; signed delayed-close/data behavior has now been observed,
but the complete signed UI scenario remains **partially qualified**. This adds the
real-browser counterpart to the existing shell-based closing tests.
It does not reimplement backup or claim abrupt-crash recovery.

The own normal HTTP page writes an original marker to a persistent cookie,
LocalStorage, a completed strict-durability IndexedDB transaction and CacheStorage.
SessionStorage is also marked, but must be empty in the next browser session.
The server verifies the original values and exports only matching booleans.

After a real page click arms `beforeunload`, the operator requests Stop through
the owned manager. The required result is an actual page confirmation and
`Closing` state. After the eight-second deadline, the same live signed browser,
lease, profile and data must remain fenced; no force-close or second launch.
Cancel the owned page confirmation, disarm it, then request Stop normally.
Reopen the same profile through the same manager. Its unchanged startup URL
serves a **read-only** page, which must observe all persistent values without
writing them again. Mere process disappearance is not proof of data preservation.

Before Stop, require the actual page text `armed; trusted=true; sticky=true`.
The guard now refuses to install the listener without both a trusted event and
sticky user activation. An AX action is not presumed to grant activation. If
the check fails, do not request Stop or claim a timeout; use a supported actual
pointer gesture on the same owned page and observe its result first.
Then use the normal own browser tab-close action as a positive control:its
beforeunload confirmation must actually appear and be cancelled. Only afterward
test manager Stop on that same document. If the positive control fails,stop the
timeout experiment;do not keep changing manager/browser flags or assume a cause.

Only `QA route direct` is exercised. The metadata sibling `QA route proxy` is
untouched. Both belong to the fixture's new isolated audit root; no real profile,
password or production Keychain item is used. Mock browser Keychain and exact
downloaded-app identity remain mandatory. No forced signal or OS network change.

```sh
python3 -B scripts/runtime-network/manager-route-fixture.py \
  --app /absolute/NeAntik.app --candidate-manifest /absolute/new/candidate-manifest.json \
  --output /absolute/new/receipts --duration 900 --manager-durability
```

Capture `written`, `pending`, `deadline`, `cancelled` and `read` with:

```sh
python3 -B scripts/runtime-network/collect-manager-durability.py \
  --state /absolute/receipts/private-state.json --stage written
```

Record the bounded native CUA observations in `durability-ui.json`:owned document,
armed fence, real confirmation, manager closing/timeout, no launch offered,
editing disabled, cancellation, disarming and read completion. The collector
independently binds each sample to the actual signed manager/browser generation,
runtime hashes, persisted metadata and lease. An unmeasurable/missing stage is
not PASS. Do not create these UI flags from intent or a screenshot of another app.

Stop the second browser normally and Quit the manager. Capture `cleanup`;
require exactly two normal main-process exits/status0, zero remaining processes,
no fixture signals and closed servers. Retire only this audit's temporary key.

```sh
python3 -B scripts/runtime-network/analyze-manager-durability.py \
  --receipts /absolute/receipts --release /absolute/repo/releases/v0.8.23.json
```

Socket/schema/model controls qualify the harness only. Actual data/GUI evidence
is still required. This scenario does not establish immediate persistence under
SIGKILL, power loss, all cookies/passwords, WebKit snapshots or full backup restore.

## Retained first native result

On downloaded135 the write/read data pair survived normal manager Stop and
reopen:cookie,LocalStorage,strict-IDB and cache matched;SessionStorage was fresh;
both main processes exited normally/status0,servers/processes drained and the
temporary QA authority was retired. The requested timeout did not occur:the
browser exited before pending collection despite the old `armed` label. That
label did not observe trusted/sticky activation. No page confirmation,deadline
or cancellation was established;the scenario is INCOMPLETE,not timeout PASS.

Pinned Chromium156 source requires a registered handler AND sticky activation
for dialog eligibility. This proves a missing fixture precondition,not the
specific cause of the retained runtime behavior. The corrected guard has pure
effect controls at that stage. That first run is retained unchanged;its missing
timeout is not retrospectively marked PASS.

## Second signed case and ordinary UI observation

The new downloaded135 case measured `trusted=true; sticky=true`, a real native
tab-close confirmation and Cancel, then manager Stop. The same signed process,
session and lease survived the sampled deadline by at least24.50seconds. Cancel,
disarm, normal Stop and fresh read preserved all four persistent stores without
rewriting;SessionStorage was fresh. Both browser exits and manager exit were0;
servers/processes drained and the temporary authority was retired.

The global timeout alert was absent because authenticated
`--neantik-release-update-audit` sets `fingerprintEvidenceReleaseContext`, and
`ContentView.workspaceAlert` explicitly returns nil for that context. This is a
fixture expectation mismatch, not evidence of a production warning bug. The
unchanged full analyzer correctly refuses `durability-native-ui-incomplete`.
**Do not replay this mode expecting its suppressed alert, or change its false UI
flag to PASS.**

A separate ordinary disposable Dev window, using the matching released135 UI
and Chromium-close sources, displayed the actual timeout warning. The same
process and lease survived at least9.44seconds;editing remained disabled and a
new launch was not offered. Cancel/disarm/Stop/Quit completed normally. This is
UI-only evidence, not exact signed-release qualification or a repeated data test.
The first private-control EOF and final exit/finish race were retained and
reconciled without replaying successful native actions.

[Combined report and explicit limitations](../../docs/evidence/manager-close-data-development.json).
Abrupt crash, power loss and WebKit snapshot/restore remain open. A future full
signed ordinary-UI test needs an explicitly isolated supported mode;Dev results
cannot replace that gate. No production change or new app release was made.
