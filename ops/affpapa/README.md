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

Check and stage without publishing:

```bash
./scripts/neantik-affpapa-release prepare /absolute/path/to/release-dir
```

Publish in one explicit transaction:

```bash
./scripts/neantik-affpapa-release publish /absolute/path/to/release-dir
```

The publish command performs local validation, clears only stale NeAntik
staging, uploads six allowlisted files, runs the server check, publishes
artifacts first and `release.json` last, then checks the live landing,
manifests, and Range sizes.

## Safety boundary

The restricted SSH identity cannot open a shell, allocate a PTY, use SFTP/SCP,
forward ports, upload Blade/PHP, or execute arbitrary commands. It can only:

- show status;
- upload allowlisted release files;
- check/dry-run/deploy the NeAntik staging transaction;
- clear only NeAntik staging;
- check or execute the latest NeAntik rollback.

The Mac App Store and App Store Connect are outside this pipeline.
