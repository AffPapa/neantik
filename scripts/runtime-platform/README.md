# Headed platform qualification

This suite promotes NeAntik's own October8–10 research fixtures into a maintained,
resumable entrypoint. It runs one signed browser at a time on a private temporary
user-data-dir, using a launch receipt exported by the actual Swift manager policy.
It never reads existing profiles, real camera/microphone input or production Keychain.

1. Prepare a Direct candidate and its authenticated candidate manifest.
2. Run `PlatformLaunchReceiptTests` with `NEANTIK_PLATFORM_LAUNCH_RECEIPT` pointing
   at a fresh private JSON path. Use the project's native Swift caches and jobs2.
3. Run `python3 scripts/runtime-platform/qualify-candidate.py --app ABS_APP
   --manifest ABS_MANIFEST --launch-receipt ABS_RECEIPT --output ABS_FRESH_DIRECTORY`.
   `--only` selects a targeted case. Keep output separate from source.
4. Review every actual JSON verdict and scope. Nonzero exits, missing contexts,
   wrong runtime/framework/source bytes and failed negative controls fail the gate.
   A resumed run reuses immutable observations only when all inputs still match.

For the first15 public-alpha release, pass that receipt via
`NEANTIK_PLATFORM_LAUNCH_RECEIPT` to `Release-NeAntik.command`. The wrapper runs
all18 headed cases on the prepared signed app before notarization. Independent
platform-state and WebGPU positive/negative controls are recorded separately.
The receipt also binds the current manager launch-builder source SHA256.

`summary-all.json` covers automatic tests for original plan rows1–15. It does not
qualify a second physical display, power/network transition, arbitrary external
HTTPS proxy route, all real hardware, or the complete1.0 production plan.
The native unconfigured WebGPU compute control is separate from NeAntik's current
configured disabled-WebGPU policy. Voices loading timeout is inconclusive.

`fixtures/promotion-provenance.json` records historical source bytes before these
maintenance changes. Current source archives are created for each observation.
These are NeAntik-authored helpers; no Fury AGPL application helper was copied.
Test fixtures are not bundled in the application and do not enlarge its download.
See AHEM-NOTICE.md for the separately licensed upstream font fixture.
