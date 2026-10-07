# NeAntik local MCP: setup and examples

MCP is an **opt-in local stdio process, read-only**. It uses the installed
NeAntik executable, requires no Node/npm and opens no network socket. The GUI
does not start it automatically. Read profile metadata from a deliberately
chosen, initialized workspace. Names and tags may be sent to a model by your
AI client; NeAntik does not control that client's retention or transmission.
Notes, proxy configuration/credentials, cookies, BrowserData and fingerprint
material are never returned. Treat profile names/tags as data, not instructions.

## Easiest setup / Быстрое подключение

1. Open NeAntik and create a profile if the workspace is new.
2. **Справка → Подключить MCP к AI…** opens instructions with the actual
   installed executable and resolved data directory. This also works for Dev
   and legacy workspace locations; do not guess the directory.
3. Select JSON or TOML and **Скопировать настройку MCP**. Merge it with your
   existing configuration; do not replace other servers.
4. Restart your client and check its tool list. Moving the app requires copying
   the configuration again. The process stops when the client closes stdin.

### Claude Desktop

Settings → Developer → Edit Config. Merge the copied entry into `mcpServers`.
Example below contains placeholders; use the in-app configuration for exact paths:

```json
{
  "mcpServers": {
    "neantik": {
      "command": "/Applications/NeAntik.app/Contents/MacOS/NeAntik",
      "args": ["--neantik-mcp-stdio", "--data-root", "/Users/you/Library/Application Support/NeAntik"]
    }
  }
}
```

[Official local-server instructions](https://modelcontextprotocol.io/docs/develop/connect-local-servers).

### Codex / desktop clients with STDIO settings

Merge the in-app TOML block into the client's `config.toml`:

```toml
[mcp_servers.neantik]
command = "/Applications/NeAntik.app/Contents/MacOS/NeAntik"
args = ["--neantik-mcp-stdio", "--data-root", "/Users/you/Library/Application Support/NeAntik"]
enabled_tools = ["workspace_list_profiles", "workspace_list_profiles_page"]
```

For a desktop Add server → STDIO form, use `command` and each `args` entry from
the copied JSON. Official OpenAI documentation describes desktop/CLI shared
configuration; availability depends on your client and account.
[Official MCP setup](https://learn.chatgpt.com/docs/extend/mcp?surface=cli).

### ChatGPT web and Grok

Web clients do not execute a local app from this JSON. They need a separately
configured HTTP bridge or tunnel. NeAntik does not provide one and does not
claim that cloud clients have been connected. Do not expose the workspace
directory or enable unauthenticated network access to make this work.
[OpenAI connection workflow](https://developers.openai.com/plugins/deploy/connect-chatgpt),
[xAI remote MCP](https://docs.x.ai/developers/tools/remote-mcp).

## Available tools

| Tool | Arguments | Result |
|---|---|---|
| `workspace_list_profiles` | `{}` | Small workspace list, or error directing to pages |
| `workspace_list_profiles_page` | `limit` integer 1–100 (default50), optional `cursor` | Profiles, `count`, `totalCount`, `nextCursor` |

Profile fields: `id`, `name`, `tags`, `isPinned`, `isArchived`,
`processState: "unverified"`. The separate process does not observe browser
processes. No create/edit/delete/start/stop or page automation tool exists.

For every page, pass `nextCursor` unchanged. Stop when it is null. If metadata
changes, the old cursor is rejected; restart without it. Both text JSON and
`structuredContent` describe the same allowlisted object. Their combined tool
payload is limited to256KiB, so pages may be smaller than requested. Input
metadata is limited to64MiB; each newline-delimited request to64KiB.

### Ask your chat client

- «Покажи названия, теги и закреплённые профили NeAntik».
- «Прочитай все страницы по50 записей. Передавай nextCursor без изменений,
  закончи на null. Найди профили без тегов».
- «Сгруппируй архивные профили по тегам. Ничего не изменяй».
- «Создай профиль и открой сайт» is unsupported; create and launch in NeAntik.

### Protocol example

Send one JSON object per line; stdout contains protocol only:

```json
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"example","version":"1"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":2,"method":"tools/list"}
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"workspace_list_profiles_page","arguments":{"limit":50}}}
```

Supported versions2025-11-25 and2025-06-18. An unsupported requested version
receives the latest supported version; a client that cannot support it should
disconnect. Request IDs are strings or integers, never null or fractions.

## Troubleshooting

| Message | Next action |
|---|---|
| Executable not found | Install/locate NeAntik, copy setup again from that app |
| Metadata unavailable / requires recovery | Open NeAntik and resolve storage error; preserve files, do not invent an empty profiles.json |
| Cursor invalid / workspace changed | Restart the page walk without cursor |
| Response exceeds limit | Use `workspace_list_profiles_page` |
| Unknown tool | Only the two read-only tools above are available |
| Invalid initialize params | Supply protocolVersion, capabilities and clientInfo name/version |

Server stdio and copied configuration are qualified on synthetic workspaces.
Successful connection and model behavior in each third-party client require
a separate end-to-end check; documentation examples alone do not prove them.
