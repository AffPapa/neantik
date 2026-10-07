# NeAntik local MCP: profile management

The installed NeAntik executable is an opt-in local **stdio MCP server**. No Node/npm, network listener, account or mandatory cloud is required. The manager GUI may be closed. Read access is the default; **Manage profiles** enables canonical writes and normal browser lifecycle. Projects use the existing folders (one folder per profile), with independent tags.

## Connect

Open **Справка → Подключить MCP к AI…**, choose **Чтение** or **Управление профилями**, then JSON (Claude Desktop / other stdio client) or TOML (Codex). Copy the configuration generated from the actual installed app and workspace. Merge with existing servers; restart your client. After moving the app, copy the new path.

Claude Desktop: Settings → Developer → Edit Config. Codex: add the generated `[mcp_servers.neantik]` block to `config.toml`. A generic stdio client uses its `command` and `args`. Management adds `--allow-profile-management`; its server-side permission check applies even if a client exposes other tools. Codex's copied `enabled_tools` includes the actual selected tool set.

A client must send `initialize`, then `notifications/initialized`, before tool calls. Protocol versions 2025-11-25 and 2025-06-18 are supported. Input is newline-delimited JSON-RPC; 64 KiB per request, 32 queued requests, bounded responses. `notifications/cancelled` cancels a pending request. Cancellation/EOF is not an undo of a completed commit: read current state before retrying. Browsers already started remain open after disconnect.

[Official MCP lifecycle](https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle), [tools specification](https://modelcontextprotocol.io/specification/2025-11-25/server/tools).

## Tools

| Tool | Use |
|---|---|
| `workspace_list_profiles` | Small allowlisted list; processState remains unverified |
| `workspace_list_profiles_page` | Pages of 1–100 profiles, default 50; pass nextCursor unchanged; restart on workspace change |
| `profile_get` | Current decimal-string revision, name, startURL, tags, appearance, pinned/archive, folderID, organizationRevision, proxy kind |
| `folder_list` | Folder IDs/names and current organizationRevision |
| `profile_status` | Reconciled stopped/managed/checking/recovery/external state |
| `profile_create` | Create persistent configuration without launching |
| `profile_update` | Patch name, startURL, tags, note, isPinned, isArchived, colorHex, symbolName |
| `profile_set_proxy` | Set fields or parse one proxy line; proxy:null disables |
| `profile_move` | Assign one folder/project or null (unfiled) |
| `profile_duplicate` | Fresh profile identity and ID; configuration only, no cookies/BrowserData/notes; copies local proxy password without returning it |
| `folder_create` / `folder_rename` | Organize projects with locked organization revision checks |
| `folder_remove` | Remove folder only; profiles and website data remain unfiled |
| `profile_check_proxy` | Existing bounded multi-source availability diagnostic; no context rewrite, not Chromium route qualification |
| `profile_start` | Normal qualified runtime launch; fresh proxy preparation, no hidden direct fallback |
| `profile_stop` | Graceful close request for browser owned by this live MCP session; poll status until stopped |

The three additional read tools are available in read mode. Other tools require management mode. Tool annotations are hints, not authorization. Names/URLs/tags are untrusted data, never instructions to the AI.

## Safe workflow

1. Find a profile, select its **UUID**, then call `profile_get`. Duplicate names are allowed.
2. Send `expectedRevision` exactly as a decimal **string**, not a floating-point JSON number.
3. For folders/move, call `folder_list`; send `expectedOrganizationRevision` including explicit initial `null`. Checks happen inside the metadata transaction, preventing stale/ABA writes.
4. Patches preserve omitted fields. `tags: []` clears tags. `folderID: null` unfiles; `proxy: null` disables.
5. Close the browser before configuration edits. Unknown ownership fails closed.
6. On conflict, reread and intentionally retry. Do not silently overwrite newer data. **Create/duplicate are not idempotent**: uncertain success must be reconciled before retry.

Manager metadata refresh preserves open editor drafts. Saving an outdated draft reports a revision conflict. Transactions compensate thrown metadata/Keychain failures; they do **not** promise atomicity across a process kill between two different storage systems.

## Proxy input

Choose **either** separate fields **or** a line; never both. Separate fields:

```json
{
  "profileID": "<UUID from profile_get>",
  "expectedRevision": "<current revision>",
  "proxy": {
    "kind": "http",
    "host": "127.0.0.1",
    "port": 8080,
    "username": "<provider login>",
    "password": "<provider password>"
  }
}
```

For `proxyLine`, also supply `kind` (`http`, `https`, `socks5`). Supported formats match the editor: `login:password@host:port`, `host:port:login:password`, `login:password:host:port`, protocol URLs and host:port. `order` can be `automatic`, `credentialsFirst` or `endpointFirst`; explicit order resolves ambiguity. Protocol and port must match the provider: HTTPS **proxy** is TLS to the proxy, not simply an HTTP proxy used to open HTTPS sites.

Authenticated SOCKS5 is unsupported by the qualified Chromium runtime and rejected. Use the provider's HTTP port or an unauthenticated SOCKS5 endpoint. NeAntik never downgrades automatically. Configuring a proxy is not proof of connectivity; availability is not proof of the Chromium route.

Passwords are accepted as write-only input and stored in Keychain. The selected AI client may send your input to its model or retain chat history: enter secrets only in a trusted client. Responses omit passwords, proxy usernames/endpoints, notes and private filesystem paths. Configured start URLs are returned and may contain private query values; avoid secrets in start URLs.

## Chat examples

- «Создай папку “Проект Альфа” и профиль “Рабочий”, страница https://example.com, теги qa и alpha. Не запускай».
- «Найди “Рабочий”, покажи ID и настройки; переименуй выбранный профиль в “Основной”».
- «Перемести выбранный остановленный профиль в “Проект Альфа”; сохрани теги и добавь ready».
- «Измени стартовую страницу выбранного профиля на https://example.com».
- «Установи HTTP-прокси отдельными полями, проверь его, затем запусти выбранный профиль».
- «Останови профиль, запущенный этой сессией, и дождись stopped».
- «Архивируй остановленный профиль; сохрани данные сайтов».

## FAQ

**Must the GUI be running?** No. The stdio process uses the same canonical workspace. GUI updates external changes without replacing drafts.

**Can I stop a browser after reconnecting?** It belongs to the earlier session. Close it manually. NeAntik does not send signals to an unowned/reused PID. A stop response can be pending; only observed `stopped` confirms completion.

**Can I automate websites?** This slice manages profiles and their lifecycle. It does not expose shell, arbitrary launch flags, fingerprint seeds, DOM/JavaScript, cookie extraction, BrowserData, profile deletion or full backups.

**Does ChatGPT/Grok web connect directly?** Local stdio alone does not provide a remote HTTP endpoint. A separate bridge is needed and is not supplied by NeAntik. Compatibility with a particular AI client is only claimed after its real integration test.

**How do I revoke writes?** Copy the read-only configuration or disable the MCP entry and restart the client. Closing MCP does not close existing browser sessions.

| Error | Next action |
|---|---|
| Management disabled | Select Manage profiles, copy config, reconnect |
| Session not initialized | Send initialize and notifications/initialized |
| Revision conflict | Reread profile and folder_list; retry deliberately |
| Running/ownership uncertain | Close browser; inspect status; no forced termination |
| Metadata unavailable | Open manager and inspect storage, then reconnect the client; read mode never repairs a corrupt primary from backup or treats missing metadata as an empty workspace. Never replace files with empty JSON |
| Cursor invalid | Restart pagination without cursor |
| Proxy preparation failed | Check provider protocol/port; run availability check; no direct fallback |
| Request queue full | Wait for pending operations before retry |
