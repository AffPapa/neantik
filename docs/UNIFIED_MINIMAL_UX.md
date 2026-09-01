# Unified Minimal UX

Research cut: 2026-08-30. This note records product decisions for the local
macOS manager. It is not a feature-parity claim or a marketing comparison.

## Product rule

The frequent path remains:

> find a profile -> confirm its state and route -> launch or stop it.

Competitors repeatedly put profiles, search, organization, route and launch in
one list. NeAntik adopts that interaction grammar without adopting the SaaS
surfaces around it. New controls must reduce time or ambiguity in this path,
stay native, preserve local ownership and justify their code and binary cost.

## Official-source review

The following pages were checked as primary evidence. A dated help article is
listed where the vendor publishes a date; otherwise the page was accessed on
2026-08-30.

| Product | Relevant current pattern | Official source |
| --- | --- | --- |
| Dolphin Anty | Profile table, search and filters, contextual bulk actions, configurable columns; separate proxy and automation surfaces | [Application interface](https://docs.dolphin-anty.com/en/interface-dolphin-anty/application-interface-dolphin-anty), updated August 2026 |
| GoLogin | Run/Stop table, quick/custom/bulk creation, editable fields, folders, tags, status and notes | [Profile fields](https://support.gologin.com/en/articles/14356784-profile-fields), [bulk actions](https://support.gologin.com/en/articles/14323620-bulk-actions), March-April 2026 |
| AdsPower | Inline quick edit and broad batch editing for profile metadata and proxy | [Edit Profile](https://help.adspower.com/docs/editing), accessed 2026-08-30 |
| Multilogin | Profiles and folders dashboard, notes and tags, staged General/Proxy/Advanced creation | [Create browser profiles](https://multilogin.com/help/en_US/start/how-to-create-and-launch-a-profile-in-multilogin-x), updated 2026-08-27; [folders](https://multilogin.com/help/en_US/working-with-groups), updated 2026-05-18 |
| Octo Browser | Profile table, inline tags, bulk tools, templates, proxy diagnostics and keyboard shortcuts | [Managing profiles](https://docs.octobrowser.net/en/profiles/edit-profiles/), [tags](https://docs.octobrowser.net/en/profiles/tags/), [hotkeys](https://docs.octobrowser.net/en/profiles/hot-keys/), accessed 2026-08-30 |
| Vision | Compact row with Start, name, proxy, status, tags and notes; selection-only mass-action bar | [About profiles](https://docs.browser.vision/profiles/overview), accessed 2026-08-30 |
| Incogniton | Profile overview, marker tags, checked bulk import and synchronizer kept as separate tools | [Knowledge Hub](https://docs.incogniton.com/), [bulk creation](https://docs.incogniton.com/browser-and-browser-profiles/bulk-browser-profiles-creation), updated July-August 2026 |
| MoreLogin | Quick/advanced/bulk creation, group/tag/note metadata, route checks and a large bulk surface | [Quick Create](https://support.morelogin.com/en/articles/10137636-quick-create), [bulk operations](https://support.morelogin.com/en/articles/10204251-bulk-operations-for-profiles), January 2026 |
| Kameleo | Local/cloud distinction, groups, notes and a proxy test outside browser launch | [Features](https://help.kameleo.io/category/11-features), [Proxy Manager](https://help.kameleo.io/article/62-built-in-proxy-manager), updated 2026-01-27 |
| Hidemyacc | Profile folders, duplicate/quick profiles, proxy manager/check, batch selection and window tools | [Manage profiles](https://docs.hidemyacc.com/hidemyacc-2.0-instructions/manage-your-profiles), [release notes](https://hidemyacc.com/release-notes), latest listed release 2026-08-06 |
| Undetectable | Split create editor, local/cloud profiles, folders/tags/notes and dedicated mass managers | [Creating and Launching](https://docs.undetectable.io/working-with-profiles/create-and-run/), updated 2026-07-31; [Mass Management](https://docs.undetectable.io/en/mass-management/) |
| NSTBrowser | Profiles, groups, tags and proxies with sync, automation, API and SDK as additional systems | [Introduction](https://docs.nstbrowser.io/guide/getting-started/introduction.html), [Profile APIs](https://apidocs.nstbrowser.io/folder-3410331), accessed 2026-08-30 |
| BitBrowser | Dense group-based table, advanced search, favorites and extensive batch operations | [Features and functions](https://doc.bitbrowser.net/help1/browser-profiles/features-and-functions), [Browser Profiles API](https://doc.bitbrowser.net/api-docs/browser-profiles), official documentation current within six months |

Across these products, the durable patterns are a scannable profile row, a
visible launch state, route context, local organization, one search field and
actions that appear when relevant. Their densest screens are produced by
team, cloud, billing, mobile, automation and marketplace requirements rather
than by the core profile job.

## Existing NeAntik baseline

NeAntik already has the parts required for the core workflow:

- a native macOS split view and one local profile store;
- active, pinned and archive scopes;
- folders, tags, notes and deterministic counts;
- search over profile name, tags, note and folder name;
- a row with text state, safe route label, bounded note preview and
  Start/Stop;
- create/edit, move, pin, archive, delete, bulk proxy import and bulk proxy
  check;
- a separate route/fingerprint inspector and fail-closed launch checks;
- proxy passwords in Keychain rather than profile metadata.

The existing default order is pinned first and then localized natural name,
with deterministic creation-time and UUID tie-breaks. The next increment
extends this projection instead of introducing a table builder or another
workspace model.

The list-first follow-up and its twenty bounded candidates are recorded in
[Vision Lean Workspace](VISION_LEAN_WORKSPACE.md). That slice keeps the same
profile store and commands while replacing the permanent detail column with an
optional native inspector.

## Accepted P0 increment

One compact `Вид` menu contains sorting and route filtering. It does not add a
toolbar row or persist another dashboard configuration.

### Sort

- `Закреплённые и название` is the default.
- `Недавно запускались` orders by `lastLaunchedAt` descending; profiles that
  have never launched are last.
- `Сначала новые` orders by `createdAt` descending.
- Pinned profiles stay first in every mode.
- Every tie is deterministic; repeated renders cannot reshuffle equal rows.

### Route filter

- `Все подключения` is the default.
- `С прокси` includes profiles with a configured proxy.
- `Без прокси` includes direct profiles.

The route filter composes with scope, folder, tag and search. It never changes
profile data or starts a network request.

Saving or duplicating a profile keeps a compatible route filter. If that
filter would hide the saved result, it returns to `Все подключения` before
selection is normalized.

### Safe route search

Search additionally indexes only non-secret route presentation values:

- the localized proxy kind name;
- the display endpoint, equivalently host and port.

It must never index or render proxy username, password, Keychain content, API
keys, raw credential URLs or password-derived values. Existing warnings not to
put passwords, keys or seed phrases in notes remain unchanged. Search folding
stays case- and diacritic-insensitive and local; no query leaves the Mac.

`Сбросить` clears search, scope/folder/tag selection and the route filter.
Sorting deliberately remains unchanged so reset does not unexpectedly reorder
the workspace.

## Gate-discovered reliability fix

The exact Chromium 152 live-manager gate showed that the managed child can
ignore Foundation's ordinary SIGTERM request. NeAntik now waits three seconds
and, only while the same manager still owns the same live `Process` object,
sends SIGKILL to that exact PID. Reconciled or external browsers keep their
existing fail-closed/manual-stop policy. This keeps Stop bounded without
weakening PID-reuse or cross-manager protection.

Browser-mode fingerprint evidence must use the exact Developer-ID signed
candidate. An ad-hoc Dev clone is useful for UI work but is not accepted as
release evidence because protected browser surfaces can differ after local
re-signing.

## Later candidates

### P1: validate demand before adding

- A contextual selection bar with only Start/Stop, route check, move and tag;
  destructive and uncommon actions remain in `Ещё`.
- Small inline editors for note, folder/tag and route, while fingerprint
  settings remain in the full editor.
- `Создать похожий`, copying organization and safe settings but issuing a new
  identity by default; do not clone an identity accidentally.
- A validated metadata/proxy import preview that excludes passwords, cookies
  and account secrets.
- Native shortcuts and drag-and-drop into folders where they do not obscure
  keyboard and accessibility paths.

### P2: separate, optional projects

- An opt-in local API with an explicit security boundary.
- A bounded route-check history and a redacted diagnostic export.
- Native multi-window arrangement for users who operate several running
  profiles.
- Reminders only after observed recurring use; they are not part of profile
  identity or launch correctness.

## Deliberately rejected for the manager

- accounts, cloud sync, teams, roles, sharing and remote workspaces;
- RPA, synchronizers, script builders and automation marketplaces;
- billing, referrals, proxy stores and embedded provider catalogs;
- cloud phones, mobile-device farms and multiple browser engines;
- account/password/2FA vaults and rich-text operational notes;
- configurable columns, custom dashboards and permanent rows of bulk buttons;
- web views, bitmap UI packs, new UI dependencies or background analytics.

These exclusions are product boundaries, not missing parity. Any future
exception requires a separate threat model, size budget and user evidence.

## Voice-of-customer caveats

Independent reviews were used only as qualitative prioritization signals.
Recurring positive themes are short setup, a clear profile list and fast
launch; recurring negative themes are crashes, lost sessions, slow launches,
forced migrations and advanced-settings overload. They do not establish market
share, defect rates or comparative quality.

The samples are self-selected; some Capterra entries are vendor-referred or
incentivized, Vision has a small public sample, vendors invite customers to
review, and Trustpilot displays an integrity warning on the Multilogin page.
Relevant review pages include
[GoLogin on G2](https://www.g2.com/products/gologin-gologin/reviews),
[AdsPower on Capterra](https://www.capterra.com/p/228046/AdsPower/),
[Dolphin Anty on Trustpilot](https://www.trustpilot.com/review/dolphin-anty.com),
[Multilogin on G2](https://www.g2.com/products/multilogin/reviews),
[Multilogin on Trustpilot](https://www.trustpilot.com/review/multilogin.com),
[Octo Browser on Capterra](https://www.capterra.com/p/10002105/Octo-Browser/reviews/),
[Octo Browser on Trustpilot](https://www.trustpilot.com/review/octobrowser.net)
and [Vision on Trustpilot](https://www.trustpilot.com/review/browser.vision).

## Release boundary

This dated design was delivered in the immutable GitHub release
`0.3.22 (25)`. Any later binary still requires a new version/build, exact
merged commit, Developer ID signing, notarization, stapling, Gatekeeper and
immutable ZIP/DMG assets.
