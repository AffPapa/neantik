# MCP / AI coverage — 0.7.23 (86)

Research and synthetic verification: 2026-10-07. The scope is local profile management, not arbitrary page automation or an assurance of checker/CAPTCHA/antifraud bypass. Chromium 154.0.8037.98 is unchanged.

## What changed

- Modern per-request MCP 2026-07-28 discovery and metadata, with legacy 2025-11-25 / 2025-06-18 initialization retained.
- Strict initialized notifications; observed cancellation suppresses the cancelled request's reply. EOF interrupts unfinished operations without killing an already opened browser.
- Folder pagination with revision-bound cursors, compact successful mutation receipts and a limit on the combined text/structured tool result.
- 17 tools: query active or archived profiles by name, project, tags and pin state; existing canonical create/edit/proxy/organization/start/stop operations. Query excludes private notes and proxy endpoints even from matching.
- Three static, user-selected prompts: organize_project, review_workspace, prepare_profile. They are instructions for a client, not automatic execution.
- Output schemas and stable namespaced error metadata. Revision conflicts and uncertain write outcomes require rereading, not blind retries.
- Seven local client configuration variants in Help → Connect MCP to AI, matching JSON/TOML/CLI requirements, preserving actual executable/workspace paths.

## Evidence

739 Swift tests, including 31 targeted MCP/help tests; 29 public-artifact privacy tests. Real Dev.app stdio: 17 tools, 3 prompts, legacy and modern paths, canonical create/update/move/duplicate/folders, secret redaction, stale revision rejection, one Chromium start/graceful stop, read-only denial and restart persistence. 29 real success payloads validated with AJV against advertised output schemas. Loopback stalled proxy probe: cancellation silent; next request completes in 0.002 seconds, EOF exit 0.004 seconds, metadata unchanged. No third-party proxy credentials used for this slice.

Synthetic metadata benchmark, same Dev debug executable and warm filesystem cache, ten samples, p95 nearest rank. Baseline is the existing list-all-pages API with client-side tag filtering in this candidate, not an older release build. No browser processes were launched for the benchmark.

| Profiles | Query p50 / p95 ms | Existing list scan p95 ms |
|---|---|---|
| 100 | 1.26 / 1.44 | 3.25 |
| 1000 | 8.04 / 8.91 | 142.19 |
| 5000 | 33.77 / 35.18 | 3148.55 |

These are synthetic local observations, not guarantees for every Mac. Query hashing/filtering runs detached; this release does not claim all manager I/O has moved off MainActor.

Real Dev GUI opened an isolated empty workspace without a data-format alert. Native UI automation lost its provider connection when opening MCP help; the new native seven-client chooser's physical keyboard/copy scenario remains unverified. Web guide client selection, management flag, JSON copy feedback and Tab navigation were exercised; 390px preview had no horizontal overflow. Real third-party AI-client accounts/models were not exercised. Configuration compatibility and server subprocess behavior are distinct from end-to-end client qualification.

## Official sources and connection limits

[MCP versioning](https://modelcontextprotocol.io/specification/2026-07-28/basic/versioning), [server discovery](https://modelcontextprotocol.io/specification/2026-07-28/server/discover), [stdio](https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/stdio), [legacy cancellation](https://modelcontextprotocol.io/specification/2025-11-25/basic/utilities/cancellation).

[Claude Desktop](https://support.claude.com/en/articles/10949351-getting-started-with-local-mcp-servers-on-claude-desktop), [Claude Code](https://code.claude.com/docs/en/mcp), [ChatGPT Desktop/Codex](https://learn.chatgpt.com/docs/extend/mcp?surface=cli), [Grok CLI](https://docs.x.ai/build/features/mcp-servers), [Cursor](https://cursor.com/docs/mcp), [VS Code/Copilot](https://code.visualstudio.com/docs/agents/reference/mcp-configuration), [Gemini CLI](https://geminicli.com/docs/tools/mcp-server/).

Web chats do not read local stdio configuration. [OpenAI Secure MCP Tunnel](https://developers.openai.com/api/docs/guides/secure-mcp-tunnels) is separate infrastructure with its own credentials and qualification; NeAntik does not install it. [Claude web](https://support.claude.com/en/articles/11175166-get-started-with-custom-connectors-using-remote-mcp) and [Grok web](https://docs.x.ai/grok/connector-management) require remote connectors. Gemini CLI does not establish Gemini web support. There is no NeAntik public HTTP endpoint.

## Deliberate limits / next backlog

Cookies/BrowserData export, arbitrary JS/shell, deletion, unattended bulk browser launches and a remote network bridge are not exposed. Stop requires ownership by the current live MCP process; after reconnect, an older browser may need manual close. Availability checks do not prove Chromium proxy routing. A→B→A is an internal release/isolation fixture, not a routine user step.

Next useful work: actual account-backed client compatibility matrix; native UI chooser smoke after provider recovery; signed one-click client bundle if official distribution contracts permit it; independently designed authenticated remote gateway; typed browser navigation/read-only page observations with origin and approval controls. Each needs its own bounded goal and tests rather than broadening this release.
