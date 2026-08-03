# NeAntik owned Chromium patchset

This directory is the handoff point for the Chromium 150 security rebase.

The current file `series.json` is a port plan, not a claim that the Chromium
150 patch files already exist. It intentionally remains a release blocker until
every `releaseRequired` group is marked `ported`, has a real patch file, and
records patch-file SHA-256 and postimage hashes from the final Chromium 150
source tree.

Run:

```bash
scripts/verify-nevision-patchset-manifest.py
scripts/verify-nevision-patchset-manifest.py --source-evidence
scripts/verify-nevision-patchset-manifest.py --release --source-evidence
scripts/verify-nevision-patchset-manifest.py --release --source-evidence --source-root /absolute/chromium/src
```

The first command validates the plan structure. `--source-evidence` also proves
that every `sourceEvidence` entry points to a real NeAntik owner file, so the
port plan cannot drift into references to deleted or imaginary files. The
release command must fail until the real Chromium 150 port is complete. With
`--source-root`, ported patch files must also pass
`git apply --check --whitespace=nowarn`.

The verifier is intentionally strict about transitional states:

- `planned` groups must keep `patchFile`, `patchSHA256`, and
  `postimageSHA256` empty, so TODO work cannot look partially ported.
- `ported` groups must provide the real safe-relative patch file, matching
  patch SHA-256, safe-relative non-empty Chromium 150 postimage hashes, and
  clean dry-run apply evidence.
- patch files are rejected if they contain forbidden scope markers from
  `forbiddenScopes` such as webdriver/headless/automation-evasion work.

Before a Chromium 150 checkout exists, export the porting workbench:

```bash
scripts/export-chromium-150-porting-workbench.py
scripts/verify-persisted-chromium-150-porting-workbench.py
scripts/export-chromium-150-owned-patchset-readiness.py
scripts/verify-persisted-chromium-150-owned-patchset-readiness.py
```

The workbench writes `dist/chromium-150-porting-workbench/candidate-evidence.json`
when the preserved Chromium 144 source root is available. That file records
current 144 postimage SHA-256 matches for overlay-derived source files. It is
evidence for porting, not release proof; `series.json` must remain
`planned-not-ported` until real Chromium 150 patches and postimage hashes exist.
The persisted verifier regenerates the workbench with the recorded timestamp
and candidate source root, then compares `workbench.json`, `README.md`,
`candidate-evidence.json`, and every TODO patch checklist byte-for-byte. Run it
after manifest, rebase-plan, overlay, or evidence changes so the handoff cannot
silently drift.

The owned patchset readiness report writes
`dist/NeAntik-Chromium-150-owned-patchset-readiness.json` and `.md`. It is the
single local gate for "can this owned Chromium 150 patchset support a public
runtime yet?" and must stay blocked until the planned groups become real
Chromium 150 patch files with hashes and a ready build root exists.

Do not port automation-evasion or bot-evasion patches. NeAntik's public
position is local profile privacy, stable separation, source/binary evidence,
and user-visible A -> B -> A measurement.
