# NeAntik AffPapa release channel

This directory is the source of truth for the least-privilege hosted release
channel at `https://affpapa.org/neantik`.

## Operator command

Both local Claude and Codex use the same wrapper:

```bash
cd /path/to/neantik-open-source
./scripts/neantik-affpapa-release doctor
```

`doctor` is the single access check: it verifies the local key permissions and
both pinned fingerprints, connects through the restricted SSH identity,
confirms that arbitrary commands remain denied, and checks the live landing,
JSON manifests, DMG and ZIP.

The wrapper pins:

- deploy key fingerprint
  `SHA256:VM+qNg4wh4bdPfBMN+0vUyeXvazmPdrlT84SfAhLs18`;
- server host-key fingerprint
  `SHA256:Q/dEY6G+KRaAk1sDgOAaaVxLZxIrQZElszGwVyn5OU8`;
- `BatchMode`, `IdentitiesOnly`, strict host-key checking, and no connection
  multiplexing.

Private keys are kept outside the repository in `../.secrets/ssh/` and are
never stored in Git, release artifacts, logs, or chat.

## Release directory contract

A candidate directory contains exactly:

```text
release.json
content.json
NeAntik-<version>-arm64-notarized.dmg
NeAntik-<version>-arm64-notarized.dmg.sha256
NeAntik-<version>-arm64-notarized.zip
NeAntik-<version>-arm64-notarized.zip.sha256
```

`release.json` is the public machine-readable release contract.
`content.json` contains the public changelog. The root-owned Blade template
reads both files, so a normal release updates version, links, SHA values, and
changelog without uploading executable PHP.

## Normal release

After the exact release commit and verified DMG/ZIP exist, generate the six
files instead of editing hashes and sizes by hand:

```bash
python3 scripts/prepare-affpapa-release-snapshot.py \
  --dmg /absolute/path/to/NeAntik-<version>-arm64-notarized.dmg \
  --zip /absolute/path/to/NeAntik-<version>-arm64-notarized.zip \
  --release-date YYYY-MM-DD \
  --output /absolute/path/to/release-dir
```

The generator requires a clean Git worktree, reads version/build/runtime from
the exact checked source, imports the first matching `CHANGELOG.md` section,
copies both artifacts, writes their sidecars and runs the same server
validator locally. It does not publish. The following `prepare` command still
repeats signature, notarization, stapling and Gatekeeper checks.

Check and stage without publishing:

```bash
./scripts/neantik-affpapa-release prepare /absolute/path/to/release-dir
```

Publish through one operator command:

```bash
./scripts/neantik-affpapa-release publish /absolute/path/to/release-dir
```

The wrapper performs the transaction in two explicit server phases:

1. validate the exact clean GitHub source/tag and re-download the GitHub DMG
   and ZIP;
2. upload six allowlisted files and stage only the immutable versioned
   artifacts;
3. re-download the full staged DMG and ZIP from AffPapa and verify their
   hashes, signatures, stapling and Gatekeeper status on the Mac;
4. activate `content.json` and then `release.json` as the atomic public
   pointer;
5. re-download and verify both live artifacts again.

Any failure after activation invokes the server rollback command. The server
also has a centralized EXIT trap, so an unexpected command failure cannot
leave partially activated metadata.

## Safety boundary

The restricted SSH identity cannot open a shell, allocate a PTY, use SFTP/SCP,
forward ports, upload Blade/PHP, or execute arbitrary commands. It can only:

- show status;
- upload allowlisted release files;
- check/dry-run/deploy the NeAntik staging transaction;
- clear only NeAntik staging;
- check or execute the latest NeAntik rollback.

The Mac App Store and App Store Connect are outside this pipeline.

Root-owned command updates are intentionally outside the restricted identity.
When these reviewed scripts change, a server administrator installs one
transactional batch with `install-server-batch.sh`; the installer backs up the
old commands, preserves live `release.json`, validates syntax/sudoers/view
cache, and records a root-owned SHA-256 manifest. Subsequent `doctor` and
`publish` calls fail closed if the server manifest differs from the reviewed
local scripts.
