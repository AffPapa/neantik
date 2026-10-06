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

## Local MCP foundation

`--neantik-mcp-stdio --data-root /absolute/path` is an explicit, read-only
local stdio mode. It is not started by the GUI and opens no socket. The
separate process uses the canonical `ProfileStore` decoder on one bounded,
regular metadata file and returns a still narrower allowlist than
`WorkspacePublicSnapshotDTO`: ID, name, tags, pin/archive flags, and
`processState: unverified`. It cannot claim a profile is running because it
does not own `BrowserProcessManager`'s live reconciliation. It never returns
notes, proxy details, exact network observations, BrowserData or fingerprint
material. The mode cannot launch/stop browsers or mutate profiles.

The initial supported MCP methods are `initialize`, `ping`, `tools/list` and
`tools/call` for `workspace_list_profiles`, using the 2025-11-25 JSON-RPC
stdio protocol. Messages are newline-delimited and requests are limited to
64 KiB; metadata input is limited to 16 MiB. A malformed or unsafe metadata
file yields a generic error. Standard output contains protocol messages only.
Configure the client to execute the absolute path of the signed
`NeAntik.app/Contents/MacOS/NeAntik` binary with these arguments and a
deliberately selected, already initialized local data root. A missing
`profiles.json` is an error rather than an apparently empty workspace. Local stdio support varies by chat
client; compatibility with Claude, ChatGPT or Grok has not yet been certified.

Future create/edit/launch tools require a separate threat model, revision
checks, process reconciliation and a user-visible confirmation model. The
current adapter is a foundation for those tools, not browser RPA.
