# Profile Isolation Evidence Harness

`verify-profile-isolation-report.py` validates a small, minimized JSON contract
for profile-isolation evidence. `run-profile-isolation-harness.py` is the
companion local filesystem/process/storage smoke harness: it creates isolated
temporary BrowserData and lock stores, writes four synthetic storage sentinels
per profile, launches separate OS child processes that hold advisory locks,
forces abrupt termination, and runs a separate recovery lock acquisition. It
never launches Chromium,
reads Keychain, or emits paths, profile names, seeds, cookies, or credentials.

## Contract

The report must contain exactly these fields, except that `runtimeHash` is
optional:

- `status`: `verified`, `partial`, `failed`, `blocked`, or `unverified`;
- `profileCount`: positive integer, at most `100000`;
- `distinctBrowserDataDirectories`: bounded integer;
- `distinctIdentitySeeds`: bounded integer;
- `sharedCookieStores`: bounded integer;
- `sharedLockFiles`: bounded integer;
- `concurrentLaunchBlocked`: boolean;
- `recoveryState`: `clean`, `recovered`, `required`, `failed`, or `unknown`;
- `storageIsolation`: `verified`, `failed`, or `unknown`;
- `generatedAt`: RFC3339 UTC timestamp ending in `Z`;
- optional `runtimeHash`: lowercase SHA-256 digest.

All distinct/shared counts must be no greater than `profileCount`. A
`verified` report additionally requires:

- one distinct browser-data directory per profile;
- one distinct identity seed per profile;
- zero shared cookie stores and zero shared lock files;
- concurrent launch blocking to be `true`;
- `recoveryState` to be `clean`;
- `storageIsolation` to be `verified`.

The verifier rejects unknown fields, duplicate JSON keys, non-standard JSON
constants, oversized input, paths, profile names, UUIDs, cookies, identity
seeds, credentials, and other arbitrary data. Those values have no place in
this minimized contract and are rejected by the strict allowlist/type checks.

`partial` is the intentional status emitted by the companion synthetic
harness. It demonstrates separate temporary filesystem inodes, distinct
synthetic storage contents, real advisory lock contention, abrupt child
termination, and a new recovery lock acquisition.
Its identity count is only a count of random synthetic in-memory tokens; it is
not a browser identity seed. It is not proof of Chromium runtime isolation,
BrowserData semantics, or long-lived resource behavior. The storage verdict
proves only that this temporary synthetic harness did not copy its markers
across its own directories; it is not a claim about arbitrary site storage.
A future authorized
Chromium producer must still emit minimized counts and enums without exporting
profile contents or sensitive identifiers.

## Local checks

From this checkout:

```bash
python3 -m unittest scripts.tests.test_verify_profile_isolation_report
python3 -m unittest scripts.tests.test_run_profile_isolation_harness
python3 scripts/run-profile-isolation-harness.py --count 3 --json \
  | python3 scripts/verify-profile-isolation-report.py -
# Expected negative result: JSON status=failed and process exit code 1.
python3 scripts/run-profile-isolation-harness.py --count 2 \
  --inject-storage-leak --json
python3 scripts/verify-profile-isolation-report.py /path/to/report.json
```

The verifier performs no network requests and has no third-party dependencies.
It does not change Swift, Chromium, runtime locks, security baselines, release
artifacts, secrets, or deployment state.
