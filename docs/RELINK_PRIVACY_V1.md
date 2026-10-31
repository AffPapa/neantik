# Privacy v1 recipient replay (Chromium156.0.8078.80, Apple Silicon)

This is a delta over the immutable v0.9.1 corresponding-source offer, not an
independent full Chromium source archive. Obtain its five ordered source parts
and parts manifest from [v0.9.1](https://github.com/AffPapa/neantik/releases/tag/v0.9.1).
Verify every part and the assembled tar using that manifest before extracting.
The base offer manifest SHA-256 is
`1a28ebe4729b0cde8f3770315a15237f4a025aec9b6fd0fcd9edfc278fcdff5a`.
Its assembled tar SHA-256 is
`679aa3526b322079d03bd83550f8b69e25f55593314c138a9e210069ae1cb77b`.
Keep published downloads, installed apps and real profiles unchanged.

Extract the base offer's source, dependencies, generated inputs, build graph,
link objects and Rust libraries into a **new disposable recipient directory**
using its `RELINK.md` instructions. Copy its corrected framework response file.
Install the Apple SDK separately and repair only the disposable SDK link as
instructed there; no Apple SDK or signing key is supplied. Use the **new** NeAntik
source archive for all following scripts, rather than the older manager source
inside the base offer.

First replay the portable CRC patch, its single-object compile and the thin
FFmpeg archive deletion exactly as documented in the base offer. Check the CRC
object and archive hashes in `runtime/chromium-15680-portable-crc.json`.
**Skip the base framework link**: the final privacy link below incorporates that
same CRC object and archive. Do not run Ninja or regenerate the build graph.

From the new NeAntik source checkout, set an absolute canonical disposable root
(`pwd -P`), then run:

```sh
export PYTHONDONTWRITEBYTECODE=1
python3 -B scripts/recipient-privacy.py
python3 -B scripts/recipient-privacy.py --source-root "$RECIPIENT_SRC" --action apply --confirm-disposable
python3 -B scripts/recipient-privacy.py --source-root "$RECIPIENT_SRC" --action compile --confirm-disposable
python3 -B scripts/recipient-privacy.py --source-root "$RECIPIENT_SRC" --action reindex --confirm-disposable
python3 -B scripts/recipient-privacy.py --source-root "$RECIPIENT_SRC" --action link --confirm-disposable
python3 -B scripts/recipient-privacy.py --source-root "$RECIPIENT_SRC" --action verify
```

Debug objects embed the compilation directory. For a different recipient root
or SDK, append `--allow-byte-differences` to compile/reindex/link/verify. That
explicit mode checks source images and archive member projections, permits local
object/framework differences, and reports the actual framework hash with
`releaseAuthority:false`. It never qualifies those bytes as the published runtime.
The CRC reference hashes likewise describe the historical build; preserve its
source/commands/member deletion when rebuilding with another toolchain.

The default is read-only recipe validation. Explicit writes validate reviewed
source preimages/postimages, compile18 existing objects sequentially, reconstruct
only four changed font thin archives with recorded flags, retain the other six
unchanged archive metadata files, then run the exact recorded link (ThinLTO jobs2).
The final unsigned framework SHA-256 is
`4446581ece6aec5e8baf990b4ef9f987da500c4e24953682d9efcebcb38f7e74`.
A different toolchain/SDK can change bytes; investigate differences rather than
relabeling them equal. This recipe verifies the recorded derivation, not arbitrary
modified source. For your own changes, update your local source/runtime bindings
and use your own signing identity under `docs/BUILDING.md` and
`docs/RUNTIME_INTEGRATION_BUILD.md`; vendor keys are not required or distributed.
Replace the framework **nested inside the actual runtime app**, then sign the
runtime and rebuild/package the manager consistently. A loose sibling framework
is not the signer input. Public signature pins are distribution gates, not a
restriction on source modification. Preserve the downloaded app for rollback.

`runtime/privacy-policy-v1` includes all18 pre/postimages, five helper sources,
compile/link/archive recipes, MPL-2.0 text and notices. The base offer retains
Chromium/FFmpeg sources and attributions; `runtime/site-protection-data` contains
the exact GPL-3.0 tracker snapshot, license and conversion recipe. Source changes
must preserve their notices. The package does not redistribute Apple SDKs.

Qualification is same-Mac compile/relink/load and bounded owned-fixture native
behavior, summarized in `runtime/privacy-policy-v1/native-smoke-20261031.json`.
A full clean Chromium rebuild, another machine, historical SDK bit equivalence,
packet-wide no-leak guarantee and absolute anonymity are not established.
This source recipe is not authority to install or claim a public release.
