# NeAntik v4 workspace: research and bounded roadmap

Research cut: 2026-08-30. “v4” is the product-design name of this source
iteration, not a public binary version. Public downloads remain `0.3.21 (24)`
until an exact merged commit passes the complete Direct Distribution release
workflow.

## Product position

NeAntik should be a native, local Apple Silicon control panel for isolated
browser profiles: the scanability of Vision and Octo, the quick profile
actions of GoLogin, and the diagnostic clarity of Dolphin and AdsPower,
without their cloud accounts, teams, billing, proxy stores, RPA, synchronizers
or arbitrary fingerprint controls.

Official product documentation consistently converges on a list-first profile
workspace, folders or groups, tags, notes, visible Start/Stop, proxy state and
selection-only bulk actions:

- [Vision profiles](https://docs.browser.vision/profiles/overview) and
  [folders](https://docs.browser.vision/folders/overview);
- [GoLogin profile organization](https://support.gologin.com/en/collections/19258652-profile-organization),
  [notes, tags and status](https://support.gologin.com/en/articles/14328143-notes-tags-and-status),
  and [profile fields](https://support.gologin.com/en/articles/14356784-profile-fields);
- [Octo profile settings](https://docs.octobrowser.net/en/profiles/browser-profile-settings/),
  [profile management](https://docs.octobrowser.net/en/profiles/edit-profiles/),
  and [hotkeys](https://docs.octobrowser.net/en/profiles/hot-keys/);
- [AdsPower profile creation](https://help.adspower.com/docs/creating_browser_profiles)
  and [profile lifecycle](https://help.adspower.com/docs/opening_closing_browser_profiles);
- [Multilogin documentation](https://www.multilogin.io/docs),
  [Incogniton documentation](https://docs.incogniton.com/),
  [Kameleo profile lifecycle](https://developer.kameleo.io/concepts/profiles/),
  [MoreLogin browser management](https://support.morelogin.com/en/articles/10137634-browser-management),
  and [BitBrowser profile functions](https://doc.bitbrowser.net/help1/browser-profiles/features-and-functions).

User reviews are treated only as qualitative signals, not proof of a defect or
a quantitative product ranking. Recurring themes are preference for a clean
interface, fast switching and folders plus tags, and frustration with RAM
growth, crashes, unclear errors and session-loss anxiety. Relevant review
collections include [GoLogin on G2](https://www.g2.com/products/gologin-gologin/reviews),
[GoLogin on Capterra](https://www.capterra.com/p/10005440/GoLogin/reviews/),
and [Octo on G2](https://www.g2.com/products/octo-browser/reviews?qs=pros-and-cons).

## Decision rules

- Keep one native window and one source of truth for profiles.
- Prefer computed views over new persisted fields.
- Make state readable as text plus a symbol; color is secondary.
- Add no network request merely to render or filter the workspace.
- Never expose credentials, fingerprint seeds, exact observed IP addresses,
  BrowserData paths or release evidence in search, rows or accessibility text.
- Never present a numeric “antidetect score” or promise that an account will
  avoid a ban.
- Any BrowserData snapshot, export or recovery feature needs a separate threat
  model before implementation.

## Seventy-five candidates

Impact uses `P0` for correctness and recovery, `P1` for the core v4 workflow,
and `P2` for bounded later projects. Cost is `L` (presentation/projection), `M`
(new local model or asynchronous measurement), or `H` (sensitive data,
BrowserData or process/runtime behavior).

| # | Impact | Candidate | Cost | Decision |
|---:|:---:|---|:---:|---|
| 1 | P0 | Launch pipeline with named runtime, signature, storage, proxy, consistency and process stages | M | Next launch/recovery slice |
| 2 | P0 | One actionable error per failed launch stage | M | Next launch/recovery slice |
| 3 | P0 | Compact Health Center for runtime, storage, process locks and profile attention | L | Attention projection started; unified center deferred |
| 4 | P0 | Permission Assistant showing the exact app name, icon and local path | M | Separate macOS-permissions slice |
| 5 | P0 | “Check again” after a permission change without relaunching NeAntik | L | Separate macOS-permissions slice |
| 6 | P0 | Dirty-shutdown marker for manager and profiles | M | Needs recovery design |
| 7 | P0 | Explicit `Closing -> Data saved -> Stopped` lifecycle | M | Needs process contract |
| 8 | P0 | Force Stop separated from ordinary Stop with a data-loss warning | M | Needs process contract |
| 9 | P0 | Pre-launch free-space guard and clear remediation | M | Next launch/recovery slice |
| 10 | P0 | Runtime state: current, stale, incompatible or blocked | M | Build on existing preflight |
| 11 | P0 | Preview of saved changes that apply only after restart | L | Editor follow-up |
| 12 | P0 | Direct-route warning: websites see the Mac’s ordinary public address | L | Implemented in v4 shell |
| 13 | P1 | One list-first workspace with collapsible sidebar and optional inspector | L | Existing foundation retained |
| 14 | P1 | Compact, standard and wide breakpoints for 820/1100/1600 widths | L | Existing foundation retained |
| 15 | P1 | Remove duplicate visual headings and keep one workspace title | L | Implemented in v4 shell |
| 16 | P1 | One adaptive command row: search, actions, filters, create | L | Implemented in v4 shell |
| 17 | P1 | Computed smart view “Running” | L | Implemented in v4 shell |
| 18 | P1 | Computed smart view “Attention” from safe process and proxy outcomes | L | Implemented in v4 shell |
| 19 | P1 | Computed smart view “Never launched” | L | Implemented in v4 shell |
| 20 | P1 | Visible counts on every smart view | L | Implemented in v4 shell |
| 21 | P1 | Active-filter chips removable one at a time | L | Existing; extended by v4 shell |
| 22 | P1 | Context-specific zero states for search, smart views and filters | L | Implemented in v4 shell |
| 23 | P1 | Session-only Comfortable and Compact row density | L | Implemented in v4 shell |
| 24 | P1 | Sticky aligned columns at wide widths | L | Existing foundation retained |
| 25 | P1 | Explicit process state separate from route health | L | Existing foundation retained |
| 26 | P1 | Proxy freshness and last-check time in the route cell | L | Existing foundation retained |
| 27 | P1 | One attention badge instead of unrelated orange symptoms | L | v4 shell projection added |
| 28 | P1 | Visible row action menu, not context-click only | L | Existing foundation retained |
| 29 | P1 | Explicit quick Note action from each profile menu | L | Implemented in v4 shell |
| 30 | P1 | Explicit row “Details” affordance on selection or hover | L | Later UI polish |
| 31 | P1 | `Command-I` inspector toggle with discoverable help | L | Existing foundation retained |
| 32 | P1 | Full keyboard path across sidebar, list and inspector | L | Continue accessibility pass |
| 33 | P1 | Selection-only action strip that can later support multi-select | M | Next workspace slice |
| 34 | P1 | Multi-select without destructive action by default | M | Next workspace slice |
| 35 | P1 | Atomic batch move-to-folder | M | Reuse store transaction |
| 36 | P1 | Atomic batch pin, archive and tag updates | M | Requires one compound mutation |
| 37 | P1 | Drag profile into folder with Undo and keyboard parity | M | After batch transaction |
| 38 | P1 | Undo for folder, tag, pin and archive metadata changes | M | After batch transaction |
| 39 | P1 | Inline note popover using existing plaintext limits and warning | M | Later editor slice |
| 40 | P1 | Searchable inline folder and tag pickers | M | Later editor slice |
| 41 | P1 | Structured optional search tokens: `tag:`, `folder:`, `proxy:`, `status:` | M | Validate after smart-view usage |
| 42 | P1 | Persist only density, ordering and panel visibility | M | No query or secret persistence |
| 43 | P1 | Quick Create split menu: configured, direct, proxy list | L | Later editor slice |
| 44 | P1 | Rename Duplicate to “Create similar” and explain fresh identity/session | L | Later copy pass |
| 45 | P1 | Editor summary: name, visible note and Direct/Proxy first | L | Existing foundation retained |
| 46 | P1 | Paste-first proxy entry | L | Existing foundation retained |
| 47 | P1 | Move repeated proxy explanations into one information disclosure | L | Later editor cleanup |
| 48 | P1 | One relevant proxy action: Test, Retry or Edit | L | Existing diagnostic foundation |
| 49 | P1 | Proxy card with outcome, latency, country, timezone and check time | M | Hide exact IP by default |
| 50 | P1 | Bulk proxy check result counts and Retry failed | M | Build on existing three-wide gate |
| 51 | P1 | Drag-and-drop proxy text file with local preview and deduplication | M | Extend current parser safely |
| 52 | P1 | Small local proxy catalog with Keychain references | M | Separate schema/threat review |
| 53 | P1 | Running strip with Focus, Stop and elapsed time | M | Process-only follow-up |
| 54 | P1 | Bounded launch queue with cancellation and concurrency cap | H | Separate process/security PR |
| 55 | P1 | Arrange running browser windows natively | M | No synchronizer or automation |
| 56 | P1 | Sanitized “Copy diagnostics” without paths, credentials, seed or IP | M | Separate privacy-reviewed slice |
| 57 | P1 | Local profile size computed asynchronously and cancelably | M | Separate performance slice |
| 58 | P1 | Total disk usage and largest-profile warning | M | Pair with pre-launch guard |
| 59 | P1 | Cold/warm manager-start budgets in CI | M | Add deterministic perf gate |
| 60 | P1 | 10,000-profile projection budget | L | Existing test retained |
| 61 | P1 | Idle CPU/RAM budget for manager only | M | Add measurement harness |
| 62 | P1 | Chromium launch-time budget | M | Runtime evidence, not UI test |
| 63 | P1 | Keep only two density presets; no arbitrary column builder | L | Product boundary |
| 64 | P1 | Split oversized SwiftUI files by presentation responsibility | L | Code-health follow-up |
| 65 | P1 | Consolidate duplicate filter and status presentation logic | L | Code-health follow-up |
| 66 | P2 | Small safe templates for organization and proxy policy only | M | No BrowserData, secrets or note |
| 67 | P2 | Config-only import/export with an explicit allowlist preview | H | Separate threat model |
| 68 | P2 | Bounded redacted activity timeline with retention and Clear | M | Separate privacy design |
| 69 | P2 | Recently deleted profiles backed by a recoverable local transaction | H | Separate recovery design |
| 70 | P2 | Last-known-good snapshot only before migration or repair | H | Separate recovery design |
| 71 | P2 | Read-only extension and sensitive preference inventory | M | No automatic mutation |
| 72 | P2 | Configured versus observed environment comparison | M | Extend current evidence model |
| 73 | P2 | Integrity seal for security-sensitive profile files | H | Separate threat model |
| 74 | P2 | Local diagnostic bundle with redaction preview before save | H | Separate privacy review |
| 75 | P2 | Optional saved local views after usage evidence | M | No cloud/team sharing |

## Implemented v4 shell boundary

This iteration implements only presentation and pure operational projection:
an adaptive command header, smart views, counts, density, contextual empty
states, a visible Note action and the Direct-route warning. It adds no package,
listener, web view, account, schema migration, secret storage, BrowserData
copy, launch argument, fingerprint behavior or Chromium byte.

The pure attention rule is deliberately conservative: a profile appears in
Attention only for a process recovery/manual-close state or a recorded proxy
check that did not succeed. A profile with no manual proxy check is not called
broken because every proxied launch performs its own fresh preparation.

## Explicit non-goals

- cloud accounts, team roles, billing and profile sync;
- RPA, synchronizers, cookie robots and “human typing” simulation;
- proxy marketplace and provider lock-in;
- mobile/cloud-phone emulation;
- arbitrary Chromium flags or manual low-level fingerprint sliders;
- cookie, token, password, seed or BrowserData export;
- a writable local or network API;
- nested folder trees;
- unlimited batch Start;
- numerical anonymity, trust or ban-avoidance claims.
