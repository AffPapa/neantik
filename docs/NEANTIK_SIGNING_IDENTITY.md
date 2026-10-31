# NeAntik signing identity

The existing NeAntik Developer ID signing identity is stored in the macOS user
login Keychain at `~/Library/Keychains/login.keychain-db`:

- Apple CLI identity selector (SHA-1): `474F7C78F33EE324C24F6F5AE0443EB713E85E60`
- Public certificate SHA-256: `781a0b9f09d3c3ac3bd34017699882ae0bec2c1ecfbbce77077ead353f592728`
- Team: `H6VGU2M6JD`
- Role: Developer ID Application for direct distribution and notarization

Certificate trust comparisons use SHA-256 or exact DER membership; the SHA-1
value is only the existing Apple CLI selector. Reviewed public pins are in
`scripts/direct_signing_identity.py`. No private key was exported or replaced.

## Safe verification

Run a read-only check in the local macOS security context that can access the
user Keychain:

```sh
security find-identity -v -p codesigning \
  "$HOME/Library/Keychains/login.keychain-db"
```

Confirm that the output contains the pinned SHA-1 and a valid identity. The
identity result means the matching private key is present; never print, copy,
or send the key. A sandboxed check may return zero even when the identity is
present. Do not interpret that result as key loss, and do not create another
certificate or ask for a new CSR before checking from the authorized local
security context.

## Storage rule

The encrypted login Keychain is the canonical store for this signing identity.
Do not put certificates with private keys, `.p12` files, passwords, or exported
key material in the repository, release artifacts, logs, or chat. Keep only
the public certificate fingerprint and this non-secret location note in the
project. If a separate disaster-recovery export is ever needed, create it only
through an explicitly protected backup workflow and store its password in a
separate secure channel; it is not required for routine NeAntik releases.

## Current observation

On 2026-10-24, a read-only local Keychain query confirmed the pinned identity
in `login.keychain-db`. Earlier sandbox-scoped queries returned zero; that was
a visibility limitation, not evidence that the private key was absent. No
certificate was issued, imported, exported, or moved during this check.
