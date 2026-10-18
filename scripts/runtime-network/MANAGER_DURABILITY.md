# Delayed close and fresh Chromium data

Development fixture; native behavior is **not yet qualified**. This adds the
missing real-browser counterpart to the existing shell-based closing tests.
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
