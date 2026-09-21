# NeAntik safe manager rollout loop

## Outcome

Deliver the ordered manager-only NeAntik improvements and qualify a new Direct
release only when the exact runtime, signing, notarization, Gatekeeper, hosted,
and rollback gates pass.

## Included

1. Profile configuration export/import UI.
2. Atomic import with folder mapping.
3. Lifecycle health center.
4. Bounded media/permissions privacy panel.
5. Route-confirmed presentation without raw IP display.
6. Extension/download provenance and quarantine policy.
7. Manager performance budgets.
8. Runtime provenance card.
9. Runtime rebase/rebuild only after explicit scope permits it.
10. Exact Direct release and live verification.

## Excluded

- CAPTCHA, ban, anti-fraud, WebDriver, automation or RPA evasion.
- JS fingerprint injection or claims of anonymity/unobservability.
- Cloud/team/cookie synchronization.
- Chromium source changes or Chromium rebuild during the current blocked stage.
- App Store and App Store Connect distribution.

## Verification types

- Programmatic: Swift tests, Python verifiers, package checks, static privacy
  scans, signing/notarization/Gatekeeper and hosted checks.
- Judge: parent review of changed surface, data boundary and exact artifact
  provenance.
- Human: only required for protected release authority or product direction
  changes not covered by the current sequence.

## Gates and stop conditions

- Plan gate: this file and `plan.md` exist before each slice is edited.
- Delivery gate: targeted tests, full Swift tests, source-tree checks and a
  privacy diff review pass for each meaningful slice.
- Stop if the same external release blocker repeats across three goal turns;
  continue manager-only work until then.
- Never call a local build a public release.

## Current state

- Goal is active in the native Codex goal system.
- Current NeAntik branch: `codex/neantik-workplaces`.
- Last manager commit: `65fe40d`.
- Completed slices: stage 1, UI file dialogs; stage 2, atomic import with
  folder mapping; stage 3, lifecycle health center; stage 4, bounded
  media/permissions privacy panel; stage 5, route-confirmed presentation.
- Current slice: stage 6, extension/download provenance and quarantine policy.
