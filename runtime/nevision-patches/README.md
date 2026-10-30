# NeAntik-owned Chromium patchset

`series.json` is the executable manifest for the owned Chromium
`152.0.7977.64` patchset.

All release-required groups are currently marked `ported`. That means the
source port is ready to build; it does not claim that a Chromium 152 binary has
already been produced, signed or behaviorally verified.

Run:

```sh
scripts/verify-nevision-patchset-manifest.py
scripts/verify-nevision-patchset-manifest.py --source-evidence
scripts/verify-nevision-patchset-manifest.py \
  --release \
  --source-evidence \
  --source-root /absolute/path/to/chromium/src
```

The verifier requires:

- a real safe-relative patch file for every ported group;
- the exact patch-file SHA-256;
- non-empty safe-relative postimage hashes from Chromium 152;
- clean patch application or exact already-applied postimages;
- real NeAntik owner files for every `sourceEvidence` entry;
- no forbidden automation-evasion, webdriver, CAPTCHA, ban or anti-fraud
  bypass scope.

The release gate fails closed if the manifest status, patch bytes or any
postimage drifts.

## Patch groups

The manifest covers:

- profile-seed contract;
- deterministic rendered surfaces;
- deterministic OfflineAudio;
- deterministic WebGL pixels;
- timezone/locale network context;
- real browser-version contract;
- reviewed Apple Silicon device tuples;
- public NeAntik branding and source lock;
- official-lite-archive build contract;
- private runtime configuration through the child-process environment;
- process-local caching of the validated profile seed.

The environment group ensures the profile seed and timezone are not exposed
through Chromium command-line arguments. The final group reads that immutable
seed once per process instead of repeating environment lookups in Canvas,
WebGL and OfflineAudio hot paths.

Historical Chromium 150 workbench and readiness scripts remain in the
repository as reproducibility evidence. They are not current release inputs and
must not be used to qualify Chromium 152.

NeAntik's public position is local profile privacy, deterministic separation,
source/binary evidence and user-visible A → B → A measurement. Do not add
automation-evasion or bot-evasion patches.
