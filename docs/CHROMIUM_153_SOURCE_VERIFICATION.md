# Chromium 153 gclient source verification

This candidate uses Chromium **153.0.8010.36**, not the latest security release.
The source contract is `runtime/chromium-153-source-contract.json`; its plan is
`runtime/chromium-153-gclient-plan.json`. The legacy 152 archive contract does not
describe this source checkout.

## Required Git implementation

The reviewed binary-diff hashes were produced with **Git 2.52.0**. Apple Git
2.54.0 produces different diff bytes for this tree even when the reviewed file
postimages are identical. Do not replace expected hashes merely to accommodate
the locally selected Git. Check `git --version` and use the reviewed tool.

On the current build host, the reviewed implementation is
`/opt/homebrew/bin/git`. Shell initialization may select `/usr/bin/git` when
starting in a different working directory. Set PATH explicitly for this check:

```sh
PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin git --version
PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin python3 \
  scripts/export-runtime-source-provenance.py /absolute/gclient/src \
  --contract "$PWD/runtime/chromium-153-source-contract.json" \
  --rebase-plan "$PWD/runtime/chromium-153-gclient-plan.json" \
  --output /absolute/evidence/source-provenance.json
```

Run from the NeAntik checkout. Paths above are placeholders except for the tool
installation location. Do not run another source sync or patch application
while verifying or compiling this checkout.

## Scope and remaining gates

The verifier checks reviewed Git changes, dependency payloads, raw downloads,
and named build tools. Successful export is **source-only evidence**. It does
not prove that a particular app was built from these inputs, or qualify signing,
notarization, privacy, runtime behavior, or publication. Candidate schema 5
must still be supported and checked throughout the release pipeline before use.
Keep the source maps and previous release available for rollback.
