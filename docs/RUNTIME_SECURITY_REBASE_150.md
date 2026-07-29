# NeAntik Chromium 150 security rebase

Checked: 25 July 2026.

## Release decision

Chromium `144.0.7559.132` is an engineering runtime only. Public Direct
distribution remains fail-closed because the checked macOS Stable baseline is
`150.0.7871.186`.

The apparent `fingerprint-chromium` tag `148.0.7778.215` is not a buildable
source release: it contains README/license/image files but no
`chromium_version.txt`, patch series, GN flags, or source manifest. NeAntik
therefore cannot safely “upgrade” by repinning that tag.

## Pinned rebase base

- `ungoogled-chromium-macos`
  `9cbd94c2b8f6f2a58a80bf32b3e01b68f3d129d4`
  (packages Chromium `150.0.7871.181`);
- `ungoogled-chromium` tag `150.0.7871.186-1`,
  commit `fd0378e4f20fa09e21b09beca71573d435d787cf`;
- replace the macOS checkout's common submodule with that exact `.186`
  commit.

Between common `.181` and `.186`, only `chromium_version.txt` and
`utils/clone.py` changed. The final build must still prove every source,
patch, toolchain, and binary hash independently.

## Minimal owned privacy patchset

Port only the privacy behavior NeAntik can review and requalify:

1. validated signed profile seed;
2. deterministic Canvas noise;
3. deterministic OfflineAudio noise;
4. deterministic ClientRects and `measureText`;
5. deterministic WebGL pixel readback noise;
6. timezone override;
7. `base::PersistentHash` from the first implementation.

Do not port automation-evasion patches (`Runtime.enable`, fake shadow roots,
webdriver, or headless hiding). Do not port random browser versions,
independent CPU/GPU guesses, or broad fake font lists.

For the shortest safe Chromium 150 release, keep real UA, Client Hints,
GPU, CPU, memory, and screen values and differentiate profiles through the
stable rendered/noise surfaces above. The experimental Chromium 144 coherent
Apple tuple implementation remains useful evidence, but it must not delay the
security rebase or be claimed as public-release proof.

The machine-readable owned patchset handoff is:

```text
runtime/nevision-patches/series.json
```

Validate the structure:

```bash
scripts/verify-nevision-patchset-manifest.py
scripts/verify-nevision-patchset-manifest.py --source-evidence
```

The source-evidence mode proves every `sourceEvidence` entry in the port plan
points to a real NeAntik owner file before the large Chromium 150 checkout is
available.

The release gate must fail until the actual Chromium 150 port is complete:

```bash
scripts/verify-nevision-patchset-manifest.py --release --source-evidence
scripts/verify-nevision-patchset-manifest.py --release --source-evidence --source-root /absolute/chromium/src
```

Each `releaseRequired` group must eventually be marked `ported`, reference a
real safe-relative patch file, include its `patchSHA256`, apply cleanly with
`git apply --check --whitespace=nowarn` against Chromium 150, and record
safe-relative postimage hashes from the final source tree.

The verifier rejects ambiguous or unsafe patchset state. A `planned` group must
not include a patch file, patch hash, or postimage hashes. A `ported` patch is
checked for a matching SHA-256 and is rejected if the patch text includes a
forbidden scope marker such as webdriver/headless/automation-evasion work.

## Apple device tuple drift guard

NeAntik maps profile identity seeds to a reviewed Apple Silicon device tuple
catalog by modulo index. Because the in-app Swift verdict and the external
Python release verifier both enforce tuple coherence, the tuple order is a
release contract.

The shared manifest is:

```text
runtime/apple-device-tuples.json
```

Verify Swift/Python/manifest consistency before accepting GUI fingerprint
evidence or porting tuple logic into Chromium 150:

```bash
python3 scripts/verify-apple-device-tuples.py
python3 scripts/verify-apple-device-tuples.py --json
```

If a Chromium 150 patch changes the tuple catalog, update the manifest, Swift
catalog, Python verifier catalog, runtime patch inputs, and GUI evidence
together. Do not reorder existing tuples casually: existing identity seeds map
by index.

Before the Chromium 150 checkout exists, generate the porting workbench:

```bash
scripts/export-chromium-150-porting-workbench.py
scripts/verify-persisted-chromium-150-porting-workbench.py
scripts/export-chromium-150-owned-patchset-readiness.py
scripts/verify-persisted-chromium-150-owned-patchset-readiness.py
```

This writes `dist/chromium-150-porting-workbench/workbench.json`,
`README.md`, `candidate-evidence.json`, and one `*.TODO.md` file per
release-required patch group. `candidate-evidence.json` is generated
read-only from the preserved Chromium 144 source root when available and
records which overlay-derived source files match the expected 144 postimage
hashes. It is only transfer evidence for the future source tree; it
intentionally does not create fake patch files or change `series.json`
statuses.
The persisted verifier regenerates those files with the recorded timestamp and
candidate source root, then byte-compares the JSON, Markdown, candidate
evidence, and TODO checklist files. Treat verifier failure as a stale handoff,
not as Chromium 150 release proof.

The owned patchset readiness report writes
`dist/NeAntik-Chromium-150-owned-patchset-readiness.json` and `.md`. It
combines the patchset manifest, persisted workbench freshness, and Chromium 150
build-root readiness into one local gate for Direct/public-runtime planning.
It remains blocked while groups are still `planned` or no Chromium 150 build
root passes preflight; it does not create patches, build Chromium, sign,
notarize, host, or publish anything.

## Required pipeline changes

- replace the third-party fingerprint submodule with an owned
  `runtime/nevision-patches/series`;
- apply every owned patch with `--fuzz=0` and a dry-run gate;
- rewrite the source lock as `chromiumBase + macPackaging + nevisionPatchSet`;
- regenerate exact postimage hashes after the real Chromium 150 port;
- update source preparation, branding preimages, phase stamps, fixtures,
  notices, and SPDX SBOM;
- build ARM64 Metal Chromium and `headless_shell`;
- capture binary and GUI A → B → A reports bound to executable/framework
  SHA-256.

## Current blocker

The existing Chromium 144 build root occupies about 26 GiB and is the only
local reproducible source/build evidence for the current runtime. The disk had
about 14 GiB free during this audit, while a clean Chromium 150 preparation
requires at least 55 GiB. Do not delete the old build root automatically.
Preserve the reports and archives, then explicitly choose storage to reclaim
or a new build volume.

The machine-checkable preflight is:

```bash
scripts/preflight-runtime-rebase-150.py /absolute/new/nevision-chromium-150
scripts/preflight-runtime-rebase-150.py --json /absolute/new/nevision-chromium-150
```

It reads `runtime/chromium-150-rebase-plan.json`, verifies the target is not
below the checked security baseline, refuses the preserved Chromium 144 evidence
root, requires a safe absolute build root, checks pinned source commits when a
checkout already exists, and blocks prepare unless the selected volume has at
least 55 GiB free.

After Chromium source is unpacked, also bind the source tree to the rebase
target:

```bash
scripts/preflight-runtime-rebase-150.py \
  /absolute/new/nevision-chromium-150 \
  --source-root /absolute/new/nevision-chromium-150/build/src
```

That gate reads `chrome/VERSION` and rejects a stale or wrong Chromium source
root before patchset, build, or release evidence is accepted.

The checked security baseline itself has a primary-source gate:

```bash
scripts/verify-runtime-security-reference.py
```

It fetches the `runtime/security-baseline.json` `reference`, requires the
official `chromereleases.googleblog.com` host, checks that the page is a
Desktop Stable Channel update with security context, and verifies that
`minimumPublicChromiumVersion` appears in that official source.
The completion audit also runs this check as a standalone
`runtime_security_reference` gate, separate from the blocked Direct public
readiness report, so stale or non-official baseline evidence cannot be hidden
inside a broader expected-blocked channel.

Before deleting anything, run the read-only disk inventory:

```bash
scripts/audit-nevision-disk-candidates.py --minimum-mib 100
```

It only inspects immediate `nevision*` children under `/private/tmp` by default
and classifies them as:

- `protected`: the Chromium 144 evidence root; do not delete automatically;
- `safe-disposable`: temporary extraction, round-trip, cache, signing input, or
  test build artifacts;
- `requires-approval`: reusable toolchains, downloaded DMGs, research material,
  or external runtime samples;
- `review`: unknown NeAntik temp artifacts that need manual inspection.

The current inventory found about 7.5 GiB of `safe-disposable` candidates,
about 12.9 GiB of `requires-approval` candidates, and about 24.5 GiB in the
protected evidence root. Even deleting only safe-disposable files is not enough
for Chromium 150; an explicit storage decision is still required.

The JSON report includes `rebaseReadiness`. On the current volume it reports
about 12 GiB free, about 19 GiB after reclaiming only `safe-disposable`
artifacts, and a remaining deficit of about 36 GiB against the 55 GiB gate.

To prepare an explicit owner-approved cleanup plan without deleting anything:

```bash
scripts/export-nevision-disk-cleanup-plan.py \
  --output dist/NeAntik-disk-cleanup-plan-latest.json \
  --markdown dist/NeAntik-disk-cleanup-plan-latest.md
scripts/verify-nevision-disk-cleanup-plan.py \
  --plan dist/NeAntik-disk-cleanup-plan-latest.json
```

The plan contains an approval token and an execute command, but generation is
read-only. The verifier checks the approval command, allowed immediate
`/private/tmp/nevision*` roots, protected evidence-root exclusion, candidate
totals, and symlink/broad-path safety. If executed later with the exact
`NEANTIK_DISK_CLEANUP_APPROVAL` token from the verified plan, execution moves
only `safe-disposable` immediate `nevision*` candidates into a quarantine
directory. It does not touch the protected Chromium 144 evidence root,
`requires-approval`, or `review` items.

After choosing a build volume that passes the preflight, generate the pinned
source bootstrap script:

```bash
scripts/generate-runtime-rebase-150-bootstrap.py \
  /absolute/new/nevision-chromium-150 \
  --output dist/NeAntik-Chromium-150-bootstrap.sh
```

The generator fails before writing if the selected root is unsafe, is the
preserved Chromium 144 evidence root, is below the required free-space gate, or
falls below the checked security baseline. The generated script is
non-destructive: it clones/checks out the pinned `ungoogled-chromium-macos`
commit and pinned common Chromium tag/commit, reruns the rebase preflight, and
runs the owned patchset manifest verifier. It does not apply unported patches
or delete existing evidence.

## Acceptance gates

- Chromium version is at least the refreshed public macOS security baseline;
- owned patches apply with zero fuzz and locked postimages;
- source and binary reports match the final source lock;
- ARM64-only Metal build and nested signatures pass;
- normal GUI A → B → A proves stable A and distinct B for Canvas, Audio,
  ClientRects, and WebGL pixels;
- UA/Client Hints equal the real compiled browser version;
- configured proxy/DNS launch controls, WebRTC loopback evidence, and
  timezone/locale coherence pass; effective HTTP/DNS egress is not observed;
- notices, SBOM, Developer ID signing, notarization, and stapling pass.

Primary sources:

- <https://chromereleases.googleblog.com/2026/07/stable-channel-update-for-desktop_01320465736.html>
- <https://github.com/adryfish/fingerprint-chromium/tree/148.0.7778.215>
- <https://github.com/ungoogled-software/ungoogled-chromium-macos>
- <https://github.com/ungoogled-software/ungoogled-chromium/tree/150.0.7871.186-1>
