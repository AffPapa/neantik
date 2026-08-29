# Workspace domain contract

NeAntik remains a native, local, macOS-only application. `ProfileStore` is the
canonical owner of profiles and their organization sidecar;
`BrowserProcessManager` owns live process state; `ProxyHealthStore` owns only
sanitized proxy-check history. None of these stores is mirrored into a second
database.

`WorkspaceDomain.snapshot(...)` takes one revision of those owners and builds
an immutable `WorkspaceSnapshot` for the SwiftUI workspace. The snapshot also
contains the bounded `ProfileEnvironmentSnapshot` used by the profile
inspector. UI labels must preserve the evidence distinction:

- `configured`: NeAntik will request this launch policy;
- `derived`: a value was calculated from local configuration;
- `observed`: a bounded local check produced evidence at a stated time;
- `unverified`: the real browser/network behavior was not measured;
- `unavailable`: NeAntik cannot produce that evidence with the current setup.

`BrowserProfile` also owns one optional local plaintext note. It is regular
profile metadata, not a secret store: it stays in the local profile document,
is not copied when the profile is cloned, and is never mirrored to Keychain or
cloud storage. The native editor, detail pane, compact list glyph and workspace
search are different views over that same canonical value. Rich text and a
second notes database are outside this contract.

The snapshot is intentionally not a network protocol. The only serializable
projection is `WorkspacePublicSnapshotDTO`, an explicit allowlist containing
folder/profile identity, tags, running/archive/pin state, proxy kind and the
latest sanitized health outcome. It has no fields for:

- BrowserData paths or visited URLs;
- proxy hosts, ports, usernames, passwords or exact observed IP addresses;
- fingerprint seeds, identity codes, runtime hashes or raw surface values;
- WebRTC candidates or network addresses;
- profile notes.

## Future adapters

Any future local API, MCP server or SDK must consume this same DTO instead of
reading JSON files independently. The first acceptable adapter is read-only,
off by default, loopback-only and authenticated with an ephemeral session
token. It must not launch/stop browsers, mutate profiles, expose Keychain
material, expose profile notes or add a network-accessible listener. Those
capabilities require a separate threat model and product decision.

The current source tree provides the shared domain and DTO only. It does not
start an HTTP listener, MCP server or background service.
