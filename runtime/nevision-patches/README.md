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

## Submitted-query search fallback

The `submitted-query-search-default` group fixes fresh workplaces inheriting
ungoogled Chromium's `No Search` fallback (`http://{searchTerms}`). It adds
a distinct distribution engine (ID 1001) through the resolver: DuckDuckGo submits queries
to HTTPS, with no remote suggestions, image search, new-tab URL, favicon,
preconnect or navigation prefetch. The separate ID and stable GUID keep the default present in the settings
catalog and reset-to-default flow. Resolver lookups preserve its minimal
endpoint definition without modifying existing built-in engine IDs.

The existing engine catalog is retained. Explicit user selections (including
No Search), extension selections and policy retain their existing precedence.
No Preferences files or hashes are edited. The manager's `--no-first-run`
behavior remains unchanged; macOS global initial preferences are not used.

This is a source patch, not proof of a rebuilt or released runtime. The old
signed runtime remains unchanged until the normal build/provenance, signing,
notarization and browser checks pass. Chromium regression tests added to
`DefaultSearchManagerTest` cover fallback endpoint restrictions and a persisted
explicit No Search selection. Run the full DefaultSearchManagerTest suite when
building the patched runtime; narrow new tests alone are insufficient.

After building, inspect a completely isolated fresh workspace: the omnibox
should name DuckDuckGo, submitting a query should navigate to its HTTPS search,
and typing without submission must not contact a suggestion endpoint. Verify
`chrome://settings/searchEngines` reflects the active default, and that choosing
another engine survives exit/relaunch. Recheck a copied test workspace with an
explicit No Search selection. Never use production profile data for this QA.

The same reviewed incremental group also leaves the fresh TopSites seed
list empty, removing the built-in link to the disabled upstream store. It does
not delete user history or custom shortcuts. The Chromium NTPTiles tests retain
visited-page coverage and add a fresh-profile no-store regression; the two
supervised-user expectations are updated to stop expecting that seeded tile.
