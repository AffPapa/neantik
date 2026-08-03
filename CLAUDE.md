# NeAntik release access

Read and follow `AGENTS.md`.

One access check:

```bash
./scripts/neantik-affpapa-release doctor
```

One public release command:

```bash
./scripts/neantik-affpapa-release publish /absolute/path/to/release-dir
```

Never use raw SSH/SCP/SFTP for this project and never request or display
private keys, Apple passwords, or notarization secrets.
