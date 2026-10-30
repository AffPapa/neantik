# Help / MCP research — 7 October 2026

This slice follows0.7.20. Three independent read-only tracks reviewed UX/copy,
the MCP contract and current competitor material. Parent owns all implementation,
tests and publishing. No Chromium source, flags, fingerprint policy or runtime
changed. No third-party extension or external AI was installed/called.

## Competitor evidence and decisions

| Product / official source | Documented useful pattern | NeAntik decision |
|---|---|---|
| [Dolphin first profile](https://dolphin-anty.com/blog/en/how-to-set-up-browser-profiles-in-dolphin-anty/) | Main vs advanced setup, step-by-step launch | Explain normal creation/launch in local help; no mandatory checker |
| [Octo templates](https://docs.octobrowser.net/en/profiles/profile-templates/), [changelog](https://docs.octobrowser.net/en/changelog/octo-browser-changelog/) | Templates, folders/tags, operation history | Already implemented; explain source and scope, no duplicate organizer |
| [AdsPower creation](https://help.adspower.com/docs/creating_browser_profiles), [MCP](https://help.adspower.com/docs/MCP) | Proxy string filling; explicit MCP installation | Existing parser retained; copy setup from current app/root. Do not copy advice to disable API verification |
| [GoLogin settings](https://support.gologin.com/en/articles/14854406-profile-settings), [proxy](https://support.gologin.com/en/articles/14810002-adding-and-managing-proxies) | Thematic settings, multiple formats, summary | Current editor retained; add contextual help and protocol/port explanation |
| [Multilogin help](https://multilogin.com/help/en_US), [proxy tests](https://multilogin.com/help/en_US/proxy-local-testing) | Beginner/features/troubleshooting navigation | Searchable task-oriented help; storage errors preserve files; diagnostics are not backup |
| [Kameleo local/cloud](https://help.kameleo.io/article/77-what-traces-does-kameleo-leave-is-the-data-online-or-offline), [quickstart](https://developer.kameleo.io/getting-started/quickstart/) | Explicit component boundaries and runnable examples | Local stdio vs AI-client/cloud boundary, exact tools and limits |
| [Incogniton proxy integration](https://docs.incogniton.com/proxy-management/integrating-proxies), [Cas](https://incogniton.com/features/cas-ai-assistant/) | Primary/fallback geo sources; assistant tasks | Existing redundant checks retained; explain429 vs proxy failure; do not advertise nonexistent write/RPA tools |

Official documentation proves documented capability, not runtime reliability
or marketing claims about stealth. No competitor fingerprint/anti-fraud claim
was validated. Relative implementation cost: local help/copy S–M, protocol
contract S; mutating MCP, full backup, cloud sync L with separate safety design.

## Reviews used as scenarios, not statistics

- [Dolphin reviews](https://www.trustpilot.com/review/dolphin-anty.com): session-cookie complaint → distinguish persistent cookies from session semantics; prior0.7.20 synthetic storage evidence retained.
- [Octo reviews](https://uk.trustpilot.com/review/octobrowser.net): older request for folders alongside tags → fresh official changelog already documents folders. Never treat stale review as current missing feature.
- [GoLogin reviews](https://www.trustpilot.com/review/gologin.com): unexpected relogin/support complaint → concrete version, error and recovery steps without credentials in support report.
- [Incogniton reviews](https://www.trustpilot.com/review/incogniton.com): stale timezone/RAM complaint → proxy revision/freshness and bounded resource testing are relevant; they are not proof of a NeAntik defect.
- [AdsPower reviews](https://www.trustpilot.com/review/adspower.com): repeated checks/fingerprint complaints → explain measured/configured facts and avoid blind repeated network probes. Review-guideline warning further prevents using ratings as reliability statistics.

## Confirmed causes and frozen changes

Existing Dev stdio reproduced successful `ping` for null/fractional IDs and
empty initialization; corrected according to [MCP basic](https://modelcontextprotocol.io/specification/2025-11-25/basic)
and [lifecycle](https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle).
Tool annotations/output follow [tools](https://modelcontextprotocol.io/specification/2025-11-25/server/tools).
Username is Codable metadata while password uses Keychain: corrected proxy
card text. README versions/MCP description and snapshot command were stale.

Nine scenarios: searchable help; contextual help/draft preservation; accurate
proxy/support copy; library explanation; exact-root copied MCP configuration;
strict requests/initialization; tool schemas/structured output; current bilingual
docs/examples; truthful landing/guide. Detailed evidence table and delivery
results live in the task artifacts. Documentation-only client examples are
never counted as successful end-to-end connections.

## Separate backlog

- Mutating MCP create/edit/launch: revision/locks/Keychain/confirmation and independent threat model first.
- Browser automation and authenticated HTTP/tunnel bridge: separate architecture and client qualification; no unauthenticated localhost listener.
- Full BrowserData backup/restore or Undo delete: transactional recovery and negative tests first.
- Physical VoiceOver, supported-macOS matrix and external AI-client end-to-end checks.
- Cached revision-bound MCP pages for very large workspaces; GUI latency measurements.
- Customer-specific launch evidence and remaining native popover focus qualification.
- Affpapa publication only when restricted client credential is available.
