# NeAntik source-branded runtime audit kit

This package performs the remaining interactive fingerprint gate for the
source-built `NeAntik Browser 144.0.7559.132`.

It is an internal Apple Silicon integration artifact. It is not a notarized
public release.

Current archive:

```text
dist/NeAntik-144.0.7559.132-source-branded-runtime-audit-kit.zip
```

The packager prints the current SHA-256 after building and verifying the ZIP.
Do not hard-code that digest inside this README: the README itself is included
in the archive, so embedding the archive hash would make the package
self-referential.

## Run

1. Extract the ZIP in Finder.
2. Open `Run-NeAntik-Runtime-Audit.command`.
3. If macOS asks, allow Terminal to open the locally built audit tool.
4. Wait for the direct WebRTC control and three browser launches:
   profile A, profile B, profile A.
5. Keep `fingerprint-audit.json` and `fingerprint-audit-terminal.log`.

The launcher applies owner-only file permissions before starting. The terminal
log records the exact production qualification output and the diagnostics path
when a run fails. It also runs `verify-gui-fingerprint-report.py` against the
saved JSON so a diagnostic/headless report cannot be mistaken for production
GUI release evidence.

After a successful user-context GUI run, inspect the private diagnostic report
from the main NeAntik project:

```bash
scripts/export-gui-fingerprint-audit-runbook.py \
  --format markdown \
  --output dist/GUI-FINGERPRINT-AUDIT-RUNBOOK.md
scripts/export-gui-fingerprint-audit-runbook.py \
  --format json \
  --output dist/GUI-FINGERPRINT-AUDIT-RUNBOOK.json
scripts/verify-gui-fingerprint-report.py \
  /absolute/path/to/fingerprint-audit.json \
  --runtime-lock runtime/fingerprint-chromium.lock.json
```

The runbook is an owner handoff for obtaining real GUI evidence. It records the
audit-kit archive hash and the exact diagnostic verification commands. The
manual
verifier binds the GUI JSON to the pinned runtime verification report through
`runtime/fingerprint-chromium.lock.json`, but the runbook is not a qualified
report by itself.

Raw schema-7 files from this kit are diagnostic only. They must never be copied
to `dist/fingerprint-audit.json` or used as Direct release evidence. A release
must run A → B → A inside the exact prepared `NeAntik.app`; that signed app
derives and signs a privacy-safe schema-8 aggregate bound to its schema-3
candidate manifest.

The audit has two deliberately different outcomes:

- diagnostic mode proves that at least two available critical browser-visible
  surfaces differ between profiles A and B and remain stable when A is
  launched again;
- production qualification additionally requires normal browser mode, all
  critical surfaces plus WebGL vendor/renderer available and stable, and
  different WebGL pixels between A and B.

## Package contents

- `NeAntik Browser.app` — source-branded ARM64 Chromium runtime.
- `NeAntikRuntimeAudit` — ARM64 CLI using the production NeAntik audit
  coordinator and probe.
- `Run-NeAntik-Runtime-Audit.command` — Finder-launchable audit command.
- `verify-gui-fingerprint-report.py` — independent JSON verifier for the
  production GUI A → B → A report.
- `evidence/` — exact source lock, GN arguments, and runtime verification.
- `licenses/` — Chromium and patch-source licenses.

## Expected result

The command writes `fingerprint-audit.json` beside itself and prints:

```text
PASS: the runtime produced a production-qualified A -> B -> A report.
```

Any `partial`, `unchanged`, or `unstable` verdict remains a failed diagnostic.
A `verified` report that came from diagnostic mode or lacks WebGL evidence is
valid engineering evidence but still fails the production release gate. The
report and preserved diagnostics are needed to diagnose either case. To re-run
only the JSON gate:

```bash
./verify-gui-fingerprint-report.py ./fingerprint-audit.json
```

Do not prepare this raw report for the release matrix. Start a fresh
candidate-bound schema-8 run from the exact prepared manager instead.

## Current release boundary

This runtime is the production-configured Metal source build. Its binaries,
Metal resources, provenance, signatures, architecture, and fingerprint
protocol passed the local integration gate after a fresh ZIP extraction. The
archive is built without AppleDouble/Finder metadata. It remains an ad-hoc
engineering artifact: production GUI A -> B -> A, Developer ID signing,
notarization, final legal review, and user-context GUI QA are separate release
requirements.
