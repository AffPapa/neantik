# NeAntik-owned Chromium 150 patchset

`series.json` is the machine-verifiable patch manifest for Chromium
`150.0.7871.186`. Its seven release-required groups are currently `ported` and
the top-level status is `release-ready`.

Run:

```bash
python3 scripts/verify-nevision-patchset-manifest.py --release
```

For a real Chromium checkout:

```bash
python3 scripts/verify-nevision-patchset-manifest.py \
  --release \
  --source-evidence \
  --source-root /absolute/path/to/chromium/src
```

The verifier checks safe relative paths, patch SHA-256 values, required
postimage hashes, source-evidence references, forbidden scope markers, and
clean patch application.

The adjacent `*.TODO.md` files are historical port checklists. The `.patch`
files and `series.json` are authoritative for the current release.

The legacy `nevision` directory name and internal C++ identifiers are retained
because they are compiled source compatibility identifiers. They can be
renamed only with a complete runtime rebuild and fresh binary, GUI, signing,
and release evidence.

Do not add automation, WebDriver/headless hiding, CAPTCHA, ban, anti-fraud, or
platform-rule evasion patches.
