# NeAntik audit handoff — 2026-09-19

## Scope

This handoff covers the local NeAntik source checkout and its engineering
evidence. It is not a Direct release approval, hosted-artifact proof, or live
network qualification.

## Verified

- Swift suite: `549` tests in `55` suites passed in a normal macOS execution
  environment on Apple Silicon.
- Process manager targeted suite: `42` tests passed, including a real
  separate-child `SIGKILL` and new-manager stale-lease recovery scenario.
- Fingerprint targeted suite: `48` tests passed.
- Public fingerprint conformance corpus: `10` synthetic cases passed.
- Network report verifier: `8` stdlib-only tests passed.
- Profile-isolation report verifier: `12` stdlib-only tests passed.
- Synthetic profile benchmark: `4` stdlib-only tests passed for profile counts
  `1`, `50`, and `100`.
- Python regression suite: `626` tests passed, with `1` environment-gated test
  skipped by its existing opt-in contract.
- Profile isolation OS-process harness: separate temporary BrowserData/lock
  stores, 3 child processes holding advisory locks, concurrent launch blocking,
  SIGKILL, and a separate recovery lock acquisition; its intentional `partial`
  minimized output is accepted by the strict profile verifier.
- Network reality producer: outside sandbox it reached a temporary self-hosted
  loopback endpoint and emitted accepted `partial` HTTP/1 evidence; DNS, TLS,
  HTTP/2/3, proxy egress, and WebRTC remain intentionally unobserved. In the
  restricted sandbox the same producer returns honest `unverified` evidence.
- Full local audit runner outside sandbox at `2026-09-19T07:21:30Z` produced
  aggregate `partial`: profile harness `partial`, network harness `partial`,
  security baseline `blocked`, and rebase preflight `blocked`.
- Latest local aggregate at `2026-09-19T07:25:11Z` remains `partial`: profile
  harness `partial`, network harness `unverified` in the restricted context,
  and both Chromium baseline/rebase checks `blocked`.
- Three Codex project agents parse as valid TOML and are read-only:
  `neantik-explorer`, `neantik-red-team`, and `neantik-release-reviewer`.
- The runtime audit skill keeps configured route, measured route, and release
  evidence as separate concepts.

## Implemented changes

- Refreshed the official macOS Chromium security baseline to `153.0.8010.52`
  / `.53`, published 2026-09-17, with 16 listed security fixes.
- Added bounded, optional fingerprint diagnostics for media-device
  availability/count, Permissions API state enums, speech-voice count, and
  worker Audio. They are backward-compatible and cannot create a strict
  production pass when missing or malformed.
- Added a privacy-safe effective-network report verifier. It rejects arbitrary
  fields, duplicate keys, IPs, hostnames, credentials, cookies, headers, raw
  ICE values, and unbounded data.
- Added a self-hosted loopback HTTP producer with an explicit `partial` result
  and an `unverified` fallback when local bind/cleanup permission is
  unavailable; it never upgrades local HTTP reachability into proxy, TLS, DNS,
  or WebRTC proof.
- Added a synthetic manager/profile projection benchmark. It does not open
  Chromium, read user profiles, access Keychain, or prove browser startup or
  CPU/RAM behavior.
- Added a strict profile-isolation evidence verifier. It checks only bounded
  counts, lock/storage separation booleans, recovery state, and concurrency
  behavior; it never accepts profile paths, names, UUIDs, seeds, cookies, or
  credentials.
- Added a companion temporary filesystem/process harness that exercises
  isolated stores, real advisory-lock contention, abrupt child termination,
  and a separate recovery lock acquisition without launching Chromium or
  exporting sensitive values.
- Added `scripts/run-neantik-local-audit.py`, a bounded aggregator that emits
  one safe summary for the local harnesses and keeps the Chromium baseline and
  rebase blockers explicit instead of hiding them in raw logs.
- Hardened Chromium rebase preflight so an explicitly declared macOS packaging
  version must match the rebase target; mixed source/package inputs now fail
  closed before disk-space, checkout, or source-root work proceeds.
- Marked the preserved 144.x audit-kit and integration-build documents as
  historical artifacts so they cannot be mistaken for the current 152
  candidate or 153-qualified release evidence.

## Unified execution list and professional prompts

The work is intentionally split by independent responsibility. The parent
task owns synthesis, code review, mutation, tests, release decisions, and live
verification. Read-only tracks may run in parallel.

1. **Chromium security and supply-chain engineer — P0.**
   Prompt: “Rebase the owned runtime to the current approved Chromium baseline;
   prove source tag/commit, dependency provenance, ARM64/Metal, SBOM, binary
   hashes, signing, notarization, stapling, and Gatekeeper for one exact
   candidate. Stop if any input is unavailable; do not substitute a newer
   number without source evidence.”
2. **Browser fingerprint and privacy engineer — P1.**
   Prompt: “Audit only observable browser surfaces and privacy-safe diagnostics;
   add bounded tests for malformed, missing, worker, and cross-profile cases.
   Never add anti-fraud bypass logic, raw ICE, cookies, credentials, or stable
   tracking identifiers. Missing evidence must remain partial/unverified.”
3. **Network-reality QA engineer — P0/P1.**
   Prompt: “Use an authorized local or self-hosted producer to emit the
   minimized network report; verify effective HTTP/DNS/TLS/HTTP2/HTTP3 route,
   zero direct WebRTC candidates, and no bypass. Keep configured route separate
   from measured route and redact all sensitive values.”
4. **macOS reliability and process-lifecycle engineer — P0.**
   Prompt: “Build a separate supervisor/child-process fixture that performs
   abrupt termination and relaunch, then proves lease recovery, BrowserData
   separation, and cross-profile isolation. Use temporary fixtures only and
   report resource-budget evidence separately.”
5. **Codex security/release reviewer — P1.**
   Prompt: “Review the exact diff and candidate evidence for secret leakage,
   unsafe release claims, stale Chromium pins, public/private artifact drift,
   and missing rollback/Gatekeeper checks. Return verified, partial, blocked,
   and unverified findings with commands.”

Recommended Codex setup:

- Keep `neantik-runtime-audit` as the primary skill for identity, profile
  isolation, route evidence, and release-facing safety.
- Keep three read-only project agents: explorer, red-team, and release-reviewer.
- Add a local process-lifecycle agent only for the bounded supervisor fixture;
  it must not edit shared release or runtime files concurrently.
- The **Codex Security** plugin is the most relevant optional addition for
  security review and secret/dependency checks, but it is not installed or
  connected in this run. Installation/connection should be a separate,
  explicit user-approved action.
- Dropbox, Box, Figma, calendars, mail, Slack, Teams, Notion, and Drive do not
  materially improve this repository audit and are intentionally excluded.

Acceptance order: baseline and provenance -> runtime build -> network reality
-> crash/relaunch -> fingerprint/profile tests -> exact-candidate GUI A to B to
A -> signing/notarization/Gatekeeper -> hosted/public/live verification.

## Partial or unverified

- The current owned runtime candidate is still Chromium 152 and is blocked by
  the refreshed security baseline.
- No new Chromium 153 binary has been built, source-bound, signed,
  notarized, stapled, or Gatekeeper-verified.
- A local temporary upstream workspace contains Chromium/common 153.0.8010.36,
  but its macOS packaging checkout is commit `038db2b`, whose own commit
  message is an update to 152.0.7977.82. The strengthened preflight correctly
  treats that mixed workspace as blocked rather than a 153 macOS contract. Its
  local macOS refs/tags also top out at 152.0.7977.82; no hidden 153 branch was
  found.
- Upstream Chromium 153.0.8010.52 and ungoogled-common 153 are available, but
  the checked public ungoogled-chromium-macos tags/releases still top out at
  152.0.7977.82-1.1. A 153 macOS packaging contract therefore cannot be
  generated honestly yet without a reviewed packaging source/commit.
- Fresh external cross-check on 2026-09-19 confirms the distinction again: the
  [ungoogled-common 153 release](https://github.com/ungoogled-software/ungoogled-chromium/releases)
  exists for Windows/macOS, while the [macOS packaging releases](https://github.com/ungoogled-software/ungoogled-chromium-macos/releases)
  still show 152.0.7977.82-1.1 as the newest listed macOS package. The
  [Chromium refs](https://chromium.googlesource.com/chromium/src.git/+refs)
  contain 153.0.8010.52 and later tags; this is source availability, not a
  signed NeAntik binary. The source contract remains intentionally pinned to
  the existing 152 candidate until a reviewed macOS packaging source/commit
  and exact build inputs are available.
- The network verifier is a contract, not an egress producer. Effective HTTP,
  DNS, TLS, HTTP/2, and HTTP/3 route observation remains unverified.
- Profile isolation and process leasing now have broad Swift coverage and a
  separate temporary filesystem/process harness. Chromium BrowserData
  semantics, packaged-runtime cross-profile behavior, and long-lived resource
  budgets remain unverified; the synthetic harness is intentionally only
  `partial` evidence.
- The local manager harness now covers a real `SIGKILL`/new-manager
  stale-lease recovery sequence. Packaged Chromium crash/relaunch evidence,
  cross-profile BrowserData proof, and long-lived resource budgets remain
  unverified until the exact runtime candidate is available.
- Public GitHub/AffPapa artifacts and live behavior were not changed or
  re-verified in this handoff.
- `docs/RUNTIME_AUDIT_KIT_README.md` and older integration documents retain
  historical 144.x kit names used by fixtures and archive documentation; they
  must not be treated as the current 152.x candidate or as a 153.x release.

## Reproducible checks

```bash
cd <neantik-open-source>
swift test
swift test --filter FingerprintAuditTests
python3 scripts/verify-public-fingerprint-corpus.py
python3 -m unittest discover -s scripts/tests -p 'test_verify_network_reality_report.py'
python3 -m unittest scripts.tests.test_run_network_reality_harness
python3 -m unittest discover -s scripts/tests -p 'test_verify_profile_isolation_report.py'
python3 -m unittest scripts.tests.test_run_profile_isolation_harness
python3 -m unittest discover -s scripts/tests -p 'test_benchmark_profile_workspace.py'
python3 scripts/benchmark-profile-workspace.py --counts 1 50 100 --iterations 3
python3 scripts/run-neantik-local-audit.py --json
python3 scripts/verify-runtime-security-baseline.py --today 2026-09-19
python3 scripts/preflight-runtime-rebase-150.py /private/tmp/neantik-rebase-check \
  --plan runtime/chromium-152-rebase-plan.json --free-gib 100 --json
```

The last two commands are expected to block the current Chromium 152
candidate; the rebase preflight reports that the target is below the refreshed
security baseline.

The aggregate runner is expected to report `overallStatus=partial` with
`runtime-security-baseline=blocked` and `runtime-rebase-preflight=blocked`
until a reviewed Chromium 153 source/binary candidate exists. It is a local
evidence summary, not a release approval.

## Current blocker

The goal is blocked on one external dependency gate: no reviewed Chromium 153
macOS packaging source/commit and exact build input chain is available. The
current NeAntik candidate remains Chromium 152, and the security baseline and
rebase preflight correctly reject it. Resume by supplying or obtaining a
reviewed 153 macOS packaging source/commit, then rerun the preflight, build,
provenance, signing, notarization, Gatekeeper, hosted, and live gates.

## Next gates

1. Rebase and build the owned Chromium runtime against the current security
   baseline.
2. Bind source provenance, binary hashes, ARM64/Metal, SBOM, signing and
   notarization to one exact candidate.
3. Extend the authorized network producer beyond loopback to controlled DNS,
   TLS, HTTP/2/3, proxy egress, and WebRTC measurements; keep every result
   partial until those observations are actually produced.
4. Add a supervisor-based crash/relaunch test that uses a separate OS process
   and proves lease, BrowserData, and cross-profile isolation after abrupt
   termination.
5. Run fresh GUI A → B → A evidence on the exact signed candidate.
6. Separately verify Gatekeeper, hosted downloads, public contract, rollback,
   and live behavior before any Direct publication.

## Continuation audit — 2026-09-20

The following safe work was completed without rebuilding or modifying the
Chromium runtime:

- Full Swift suite passed: `549` tests in `55` suites.
- Python regression suite passed: `626` tests, with the existing single
  environment-gated skip.
- The abrupt-child recovery test now validates that the lease PID is live
  before accepting an external process identity; the targeted test and full
  suite pass.
- Production Secure Enclave enrollment/signing no longer creates, reads, or
  signs with a software P-256 Keychain fallback. Missing Secure Enclave
  entitlement remains a hard failure, matching the schema-8 release policy.
- The aggregate local audit now pipes both producer reports through their
  strict allowlist verifiers and derives the security-baseline date from the
  current UTC date. Fresh output remains honest: profile harness `partial`,
  network harness `unverified` or `partial` depending on local permissions,
  and both runtime checks `blocked`.
- The master-plan verifier and website handoff packer now use the current
  `docs/NEVISION_MASTER_PLAN_RU.md` filename. The verifier and its three tests
  pass.
- Runtime integration and supply-chain documents now state that the local
  Chromium 152 candidate is below the current Chromium 153 baseline and is
  not a public release candidate.
- A fresh temporary profile harness reported three distinct BrowserData
  directories and identity seeds, zero shared cookie/lock stores, blocked
  concurrent launch, and clean recovery. A fresh loopback network report
  observed only local HTTP/1 reachability and correctly left DNS, TLS,
  proxy-egress, HTTP/2/3, and WebRTC unobserved.
- Local Sites HTTP smoke returned `200` with the product-first section before
  the comparison matrix, the blocked-release message, and no GitHub archive
  download URL in the rendered HTML.

The public NeAntik landing source is saved in Sites as version 83 from exact
source commit `38ec353762639fc838f8d07197e831860200d061`. Version 83 keeps
the download contract fail-closed until the Direct candidate is verified; the
public deployment remains a separate pending operation. The current live
`https://browser.free` smoke check still serves the previous landing copy. No
Chromium source, binary, signing material,
profile data, cookies, proxy credentials, or release secrets were changed.

Follow-up correction from the Direct-only plan audit: the separate Mac App
Store track is now explicitly classified as archived/out-of-scope in the
NeAntik completion audit; it no longer inflates the unfinished Direct plan.
The native Swift verification was rerun with writable isolated caches and
passed: `253` tests in `21` suites. The site manifest parser now accepts
compact inline fields in `release.ts`; the real cross-project version drift
(`nevision` app `0.3.14` versus site `0.7.3`) remains correctly blocked rather
than being auto-aligned without an exact release artifact.

Remaining blockers are unchanged and explicit: no reviewed Chromium 153
macOS packaging/source chain, no exact signed/notarized candidate, no fresh
GUI A -> B -> A evidence for that candidate, no packaged-runtime network or
crash/relaunch proof, missing local AffPapa deploy key for `doctor`, and
pending owner confirmation before deploying the public Sites version 83.

Additional safe continuation on 2026-09-20:

- The native manager-only bundle was rebuilt with `scripts/package-app.sh`
  without touching Chromium. `scripts/verify-release.sh dist/NeAntik.app`
  now passes for the documented pre-integration bundle: arm64, codesign,
  telemetry, update policy, fingerprint corpus, Russian UI labels, and clean
  NeAntik manager branding.
- The branding verifier now has an explicit manager-only mode. It still
  requires an embedded runtime for an integrated/public candidate, so this
  change does not weaken the Direct runtime gate.
- Fresh completion audit now proves `native_minimal_apple_silicon_manager`,
  `profile_and_proxy_basics`, privacy statistics, storage plan, and the
  Direct-first master plan. The remaining incomplete requirements are the
  compatible Chromium runtime, exact distribution artifacts, handoff
  integrity, site/artifact alignment, and public Direct distribution.
- Finder metadata was removed only from the exact `nevision/dist` artifact
  tree and moved to a private temporary backup directory for recovery.
  `scripts/verify-dist-clean.py` now passes; no source, secret,
  runtime, or rollback archive was deleted.
- Direct release matrix, dist inventory, Direct readiness, signing/notary
  packet, GUI readiness snapshot, and the two Direct owner runbooks were
  regenerated or synchronized. Their verifiers now pass where the evidence
  is local; blocked runtime/archive gates remain explicit. Archived Store
  runbooks are no longer part of the Direct owner-runbook completion gate.
- A fresh local Sites preview returned HTTP `200`; the product/profile
  explanation appeared before the comparison section, the blocked-release
  copy was rendered, and no GitHub archive download URL appeared in the HTML.
  The preview process was stopped afterward; no public deployment was made.

Latest continuation audit — 2026-09-20:

- The current Chrome Releases baseline was refreshed from the official
  2026-09-17 Stable Channel post: macOS `153.0.8010.52/.53`, 16 security
  fixes, checked on 2026-09-19. The reference verifier passes in the permitted
  network environment. No Chromium source or binary was rebuilt.
- The NeAntik site release contract now matches the real manager-only app
  `0.3.14 (17)`. Its release metadata uses the recorded archive checksum but
  intentionally allows the local archive to remain absent while the integrated
  runtime candidate is blocked. The site manifest verifier passes and the
  download CTA remains fail-closed.
- The landing copy is product-first: NeAntik explanation, isolated profiles,
  modern anti-fraud-compatible profile technology, local storage, simple UX,
  and the image-product/free-product rationale appear before the comparison
  matrix. Product HTML contains no defensive guarantee wording.
- The persisted Direct release matrix, Direct install runbook, owner runbooks,
  site build/tests, master-plan verifier, and current completion audit were
  synchronized. The completion audit has zero failed checks; remaining states
  are expected-blocked Direct/runtime artifacts and explicit out-of-scope
  Chromium-150 rebuild work.
- The permitted native Swift run passed `253` tests in `21` suites. The local
  runtime audit remains honestly partial/unverified for packaged Chromium
  behavior and network egress because the exact integrated runtime is absent.

The public Sites version remains saved but undeployed. No public URL, release
archive, signing material, profile data, cookies, proxy credentials, or secret
was changed during this continuation.

Latest continuation audit — 2026-09-21:

- The native Swift suite passed `550` tests in `55` suites after the runtime
  signature preflight hardening. An uninspectable code signature is now a
  launch-blocking error rather than a warning.
- The local profile harness remains intentionally `partial`; the network
  harness remains `unverified` in the restricted environment. Neither result
  is promoted to packaged-Chromium or proxy-egress proof.
- Public GitHub Releases were checked read-only. The latest immutable release
  is `v0.7.3` with four uploaded assets; this checkout is not that exact
  release commit and must not be published as a replacement without a fresh
  candidate chain.
- The source-tree hygiene gate now passes after removing personal absolute
  paths from this handoff. Chromium was not rebuilt, and no public release was
  created or uploaded.

Latest manager completion audit — 2026-09-21:

- The current native Swift gate passes `575` tests in `61` suites. The
  manager-only production build also passes; the loopback permission needed by
  the STUN test was granted only for verification and did not change source or
  runtime artifacts.
- Python scripts pass `631` tests with one expected skip. Open-source tree,
  public workflow references, generated runtime notices, signed-update policy
  and disabled Direct telemetry checks pass.
- `docs/NETWORK_REQUEST_INVENTORY.md` records the confirmed manager network
  surfaces and keeps Chromium background requests `unverified` until an exact
  runtime/source evidence cycle exists.
- The official Stable baseline was rechecked on 21 September: macOS
  `153.0.8010.52/.53`; ungoogled common has `153.0.8010.52-1`, while the
  public ungoogled macOS packaging release list still ends at
  `152.0.7977.82-1.1`. The checked NeAntik source candidate remains Chromium
  `152.0.7977.64`; no version substitution or rebuild was performed.
- Aggregate audit remains `partial`: profile isolation is `partial`, network
  reality is `unverified`, and runtime security/rebase are `blocked`. Direct
  publication remains stopped until a reviewed macOS 153 source/packaging
  pair, exact runtime evidence, and the configured deployment credential are
  available.
