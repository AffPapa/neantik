# Local NeAntik build retention

This policy is not an automatic deletion daemon. Inventory is read-only.

## Keep

- One installed production app at `/Applications/NeAntik.app`.
- One active checkout's `.build/neantik-local/NeAntik-Dev.app`.
  `Develop-NeAntik.command` already reuses this path on each build.
- One current release candidate until publication and installation are verified.
- One explicitly selected previous working release for rollback.
- Profiles, Keychain, source repositories, runtime sources, signing/provisioning
  files, notarization receipts and release manifests are never cleanup targets.

## After a successful new Direct release

1. Verify the installed exact version/build, downloaded archive SHA-256,
   Developer ID, notarization, stapling, Gatekeeper and a profile launch/stop.
   A successful compile or version number change is NOT sufficient.
2. Select the single previous working rollback explicitly in a manifest.
3. Inventory all known local checkouts. Resolve each obsolete outer bundle;
   never remove nested Chromium components separately.
4. Confirm no process, mounted disk or active notarization transaction references
   a candidate. Unknown/submitted/in-progress transactions are protected.
5. Move reviewed obsolete app bundles and duplicate downloaded archives to Trash;
   log original path, destination, version and hash. Preserve original signed
   archives until their immutable GitHub copies have been re-downloaded/verified.
6. Verify current app, Dev, rollback and profile data remain present.
7. Trash is NOT automatically emptied. Irreversible disposal is a separate,
   explicit action; do not promise reclaimed disk space before it.

## Prevent accumulation

- UI work uses only the designated active checkout and Develop command. Do not
  build additional Dev copies in historical checkouts.
- Do not download release binaries repeatedly into unrelated tool directories.
- End every release cycle with the inventory/retention checkpoint above.
- A future automatic cleanup hook must consume verified release/install evidence
  and an exact allowlisted manifest. Do not hook blind deletion to app launch,
  build success, a calendar age, or the mutable Git branch/version name.
- Keep cleanup failures independent from publication: report them without
  deleting current or rollback artifacts to make a cleanup check pass.

Run the read-only inventory:

```sh
python3 scripts/inventory-local-neantik.py --workspace /absolute/path/to/workspace
```
