# Own Chromium main-process crash recovery

Development harness. The downloaded signed 0.8.23 (135) completed the three
headed sessions on 18 October. Data and custody layers were observed; the whole
scenario remains **partial** because one pre-page HTTP refusal has no recorded
cause. [Result and limits](../../docs/evidence/manager-crash-0.8.23-development.json).
Model and socket controls do not establish browser durability. This is a separate scenario from
the already retained delayed-close1352;do not repeat that case or its missing
audit-mode alert.

## What is tested

One isolated Direct Chromium profile uses three browser sessions, the same own
HTTP origin and unchanged startup URL:

1. Write baseline A to cookie,LocalStorage,strict IndexedDB and CacheStorage.
   Stop normally. This establishes pre-crash data,not the crash result.
2. On the next launch,read A before any writes. Write a separate strict-IDB
   marker B and await `transaction.oncomplete`. A second transaction successfully
   executes `put`,then aborts;its value must remain absent. Separate new cookie,
   LS and cache keys are observations,not strict durability promises.
3. The custody collector may send exactly one SIGKILL to that verified own main
   process. Observe its actual reason2/status9,disappearance of the captured
   process generations,retired lease and empty error-free open-file inventory.
   Only then relaunch through the same manager. Read without creating a missing
   database/cache,writing original values again or repairing them.

The hard data criteria are intact baseline A,acknowledged strict-IDB B and
absence of the aborted value. SessionStorage restoration and freshest cookie,
LS/cache presence are reported separately. Main-only SIGKILL is not simultaneous
death of every storage service,power failure,relay crash or WebKit recovery.

The native case preserved baseline A and acknowledged B; the aborted value was
absent. The newest cookie was lost, while fresh LS/IDB/cache were present. The
restore-pages prompt was visible, but its action and restored tabs were not
tested. Actual exits were 1/0 → 2/9 → 1/0; captured processes, lease and open-file
inventory were clear before relaunch. Manager and fixture exited normally, and
the temporary QA authority was retired. This is not power-loss qualification.

## Why the distinction matters

Read-only source review used Chromium commit
`634b046faf2137b83af71c87baf362b533af9104`:

- `content/browser/indexed_db/instance/transaction.cc:1001` completes after the
  backing-store commit. LevelDB Strict maps to synchronous writes in
  `instance/leveldb/backing_store.cc:1461`;SQLite uses synchronous FULL.
- `net/extras/sqlite/sqlite_persistent_cookie_store.cc:339` batches mutations,
  including a30-second timer. `document.cookie` readback is not a flush barrier.
- `components/services/storage/dom_storage/local_storage_impl.cc:45` has a
  default5-second commit delay,with rate limiting in `storage_area_impl.cc:685`.
- Awaited CacheStorage completion has no strict-persistence option. For example,
  `net/disk_cache/simple/simple_entry_impl.cc:488` can retain data in memory.

Do not turn loss of an unflushed freshest value into an automatic product bug.
Loss of the established baseline or acknowledged strict-IDB marker requires
investigation. Keep failures and actual I/O errors;do not relax acceptance to
obtain a green report.

## Operator sequence

Use the exact downloaded signed app,one new candidate-scoped QA authority and
private manifest. Fresh native admission,private roots,mock browser Keychain,
source freeze and custody requirements are unchanged. The two generated profile
names are `QA route proxy` and `QA route direct`;only Direct is exercised.

```sh
python3 -B scripts/runtime-network/manager-route-fixture.py \
  --app /absolute/NeAntik.app --candidate-manifest /absolute/new/candidate-manifest.json \
  --output /absolute/new/run --duration 1200 --manager-crash

python3 -B scripts/runtime-network/collect-manager-crash.py \
  --state /absolute/new/run/private-state.json --stage baseline
```

After native baseline completion,capture `baseline`,then normal Stop. Launch
again;observe mutate completion,capture `mutate`. The `signal` stage revalidates
the exact live manager/main generation,path,code,lease,profile,source/runtime
hashes and actual browser-bound write receipt. It records intent before any
signal,refuses a repeated attempt and never signals helpers or a process group.
Capture `after-crash` only after real cleanup;missing or unknown custody is not
stopped. Observe stopped UI before relaunch,then read completion/capture `read`.

Stop normally,Quit manager,wait for the fixture's terminal exit,and capture
`cleanup`. Record only actually observed UI flags in `crash-ui.json`. Retire
only this run's authority through the existing narrow retirement operation.

```sh
python3 -B scripts/runtime-network/analyze-manager-crash.py \
  --receipts /absolute/new/run --release /absolute/repo/releases/v0.8.23.json
```

The default analyzer still refuses the retained native case with
`crash-page-protocol`. Explicit `--components-only` reports independently checked
data/custody layers and the refusal count, with `fullScenarioQualified=false`
and `releaseGate=false`. It cannot excuse a lost baseline, failed strict commit,
incomplete cleanup or missing UI observation. Do not rewrite raw receipts or
repeat the crash to fix offline analysis. Add bounded stage/cause diagnostics
before any future startup experiment; the old refusal remains unclassified.

Future requests now record fixed `stage` and `reason` codes, plus the fixture
phase at arrival/refusal. Header EOF, header limit, timeout, custody failure,
page/receipt validation and response-send failure can be distinguished without
recording headers, body, target URL, exception text or peer identity. A failed
send does not undo prior page/result events or mean the client acknowledged
them. Every `crash-http-refused` remains fatal to full qualification. These
diagnostics passed handler and loopback controls; they have not classified the
historical native event. Its original source archive/hashes remain unchanged.
A separate [single headed startup](../../docs/evidence/manager-startup-0.8.23-development.json)
on downloaded135 then produced one accepted page/receipt and zero refusals,
normal Stop/Quit, cleared process generations/lease/files and successful QA-key
retirement. Twelve mutations of those receipts were rejected. No crash,
relaunch or durability matrix was repeated. Absence of a new refusal is not a
diagnosis or reclassification of the old event; retain its partial result.

For authority retirement, preserve the existing narrow operation's path
contract. An original runtime executable with multiple hardlinks is refused by
its stable-file guard. Use a byte/inventory/signature-verified, never-launched
inspection copy under the artifact directory; do not remove an unknown link or
relax the guard. `/tmp` canonical-argument validation and descriptor traversal
through `/private/tmp` are distinct requirements: reuse the established helper's
layout rather than retrying path spellings. Native-case records retain all four
setup refusals and the final successful retirement.

The analyzer requires three fresh sessions of the same metadata identity,
actual exit sequence1/0→2/9→1/0,one intentional main signal,zero cleanup signals,
native UI observations and original read-only values. Peer attribution code is
pinned too. It does not claim native visibility of every intermediate helper
fence or qualify the whole release. No app rebuild is needed for this harness.
