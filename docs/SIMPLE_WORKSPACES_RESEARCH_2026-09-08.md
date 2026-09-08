# NeAntik 0.4 — open and work

Research cut: 2026-09-08. Eighteen documented products and concrete public
reviews of thirteen products, with overlapping samples. This is purposive
qualitative research, not a representative survey or hands-on competitor
benchmark. A new interaction is proposed and implemented below; neither
novelty nor universal reliability is established by this research.

## Product decision

NeAntik should make a persistent local profile feel like a familiar workspace:
create it once, open it, return to its existing window, and understand the
specific problem if opening fails. The default path should not require a
manual diagnostic, fingerprint quiz, registration, country guess or platform
preset. Existing stable identity, local storage, Keychain transactions and
automatic route preparation are foundations, not new inventions.

Quick creation is already documented by [Octo](https://docs.octobrowser.net/en/profiles/start/),
[GoLogin](https://support.gologin.com/en/articles/14322174-creating-profiles),
[Multilogin](https://multilogin.com/help/en_US/help/quick-browser-profiles)
and [Dolphin](https://docs.dolphin-anty.com/en/getting-started/quick-start-in-dolphin-anty).
Dolphin expressly describes site type as organizational. NeAntik should not
turn “TikTok” into an unsupported promise about fingerprint quality.
Some competitors' quick profiles are temporary; NeAntik's ordinary profiles
remain persistent. Fast creation must not imply losing a session on close.

## What public feedback supports

| Signal | Evidence and counterevidence | Decision |
| --- | --- | --- |
| Session continuity | [GoLogin](https://www.trustpilot.com/review/gologin.com), Sep 1 2026: cookie-save incident reportedly fixed; other contemporaneous reviewers praise stable sessions and speed. [Dolphin](https://uk.trustpilot.com/review/dolphin-anty.com), May 8 2026: reported repeat logouts. These incidents were not independently reproduced. | Preserve data and identity. A failed launch must retain the saved profile, with retry against that same profile. |
| Too much manual repair | Dolphin Feb 28 and Aug 28 2026 reviews describe manual browser-version adjustment, including a positive review. | Do not ask users to manage runtime/UA coherence. Keep a tested embedded engine and automatic launch preparation. |
| Organization remains useful | [Octo](https://www.trustpilot.com/review/octobrowser.net), May 29 2026: clean UI praised but folders requested; [MoreLogin](https://uk.trustpilot.com/review/www.morelogin.com), Apr 17 2025: column width and bookmark-folder persistence requested. Current features may differ from old reviews. | Keep folders, notes and tags. Hide rarely used controls rather than deleting useful organization. |
| Proxy explanations matter | [Vision](https://uk.trustpilot.com/review/browser.vision), Oct 11 2024: location mismatch; vendor explains geolocation database differences. [ixBrowser](https://uk.trustpilot.com/review/ixbrowser.com), Mar 21 2026: same IP in new profile surprises reviewer. | Explain Direct route; do not imply a new profile changes IP. Derived geo is approximate; a manual probe is not proof of Chromium egress. |
| Expert control vs simplicity | [Undetectable](https://www.g2.com/products/undetectable-io/reviews), Dec 16 2025: useful but technical knowledge needed; review incentivized. [Kameleo](https://www.g2.com/products/kameleo-kameleo/reviews), Jul 2024: easy proxy integration praised, very small sample. | Paste-first entry with manual fields on demand; valid pasted input should not require an extra Apply step. |
| Cost of diagnosis | [AdsPower](https://www.trustpilot.com/review/adspower.com), Aug 5 2026: reviewer reports repeated tests consuming paid proxy traffic; cause unverified. | No background diagnostic loop or automatic repeated network retry. One bounded required preparation when the user opens a proxied profile. |

Trustpilot displayed removed-fake-review notices for AdsPower and Multilogin.
G2 labels some entries incentivized. Sparse samples, self-selection, vendor
replies and contradictory performance reports prevent product rankings or
defect-rate estimates. Claims of theft, bans and “undetectability” are not
accepted as causal evidence. The remaining reviewed products were Incogniton,
Hidemyacc and adjacent Ghost Browser; detailed dated evidence remains in the
local cycle's `reviews.md` and `workflows.md`.

## Documented workflow comparison

| Product | Useful pattern | NeAntik boundary |
| --- | --- | --- |
| [Vision](https://docs.browser.vision/profiles/overview) | Visible row action and context | No configurable spreadsheet subsystem |
| [Dolphin](https://docs.dolphin-anty.com/en/getting-started/quick-start-in-dolphin-anty) | Recommended defaults, site label only | No platform-specific technical claims |
| [GoLogin](https://support.gologin.com/en/articles/14322174-creating-profiles) | Quick/default creation | No account or cloud-sync wait |
| [Multilogin](https://multilogin.com/help/en_US/help/quick-browser-profiles) | Quick and regular lifetime distinction | Persistent by default |
| [AdsPower](https://help.adspower.com/docs/creating_browser_profiles) | Optional proxy, automatic defaults | Avoid routine checker tab |
| [Octo](https://docs.octobrowser.net/en/profiles/start/) | Quick create and launch-time connection check | Explain actual route before launch |
| [Incogniton](https://incogniton.com/getting-started/) | Name-first profile | No browser-version selection |
| [Kameleo](https://help.kameleo.io/article/74-recommended-settings) | Coherent defaults and proxy-derived context | No silent identity changes |
| [MoreLogin](https://support.morelogin.com/en/articles/10137636-quick-create) | Separate quick/advanced paths | Don't make Quick another long questionnaire |
| [Undetectable](https://docs.undetectable.io/working-with-profiles/create-and-run/) | Save and open | Don't mix temporary/permanent semantics |
| [Linken Sphere](https://ls.app/docs/sessions/creating-and-launching-session) | Continuity and prior tabs | Tab restore deferred pending data-consistency review |
| [SessionBox](https://sessionbox.io/learning/what-is-SessionBox) | Understandable separate sessions | Not equivalent storage/fingerprint architecture |
| [Firefox Containers](https://support.mozilla.org/en-US/kb/containers) | Context names/colors and site assignment | No ambiguous automatic domain routing |
| [Safari profiles](https://support.apple.com/en-ie/105100) | Native topic-oriented contexts | Do not adopt shared-password assumptions |
| [Nstbrowser](https://docs.nstbrowser.io/guide/getting-started/quick-start.html) | Launch with prepared defaults | Preserve draft/profile on network failure |
| [BitBrowser](https://doc.bitbrowser.net/help1/browser-profiles/add-a-new-browser-profile) | Organized configuration | Don't become an account/password inventory |
| [DICloak](https://help.dicloak.com/browser-profiles/) | Notes and contextual operations | Keep secondary actions contextual |
| [Hidemyacc](https://docs.hidemyacc.com/hidemyacc-2.0-instructions/create-hidemyacc-profile) | Automatic environment settings | No unsupported masking claims |

Apple's [Onboarding](https://developer.apple.com/design/human-interface-guidelines/onboarding)
and [Settings](https://developer.apple.com/design/human-interface-guidelines/settings)
guidance supports reasonable defaults and minimal setup. Its
[Alerts](https://developer.apple.com/design/human-interface-guidelines/alerts)
guidance supports concise, specific situations and action verbs. Applied here:
normal tasks remain visible; diagnosis is available in Help and error recovery.

## Implementation and acceptance matrix

| Change in 0.4 | Before | Intended acceptance |
| --- | --- | --- |
| Suggested name | Mandatory naming before valid submit | Editable unique name, no save before explicit action |
| Create and open | Create then locate and Start | Persist once, dismiss sheet, re-read profile, launch; create-only available |
| Paste-first proxy | Import controls plus manual fields plus manual probe | Short paste path, redacted preview, detail disclosure, explicit ambiguous-order handling |
| Automatic submit parsing | Valid pending import blocks Save | Parse locally on commit; invalid input retained and cannot fall back to Direct |
| Automatic preparation copy | “Check again” for changed configuration | Explain actual automatic next-launch preparation; preserve real error results |
| Return to window | Primary running action stops browser | Primary focuses verified window; separate Stop and guarded recovery states |
| Neutral new start | External fingerprint diagnostic every launch | New profiles use exact about:blank; previous/custom URLs unchanged |
| Contextual diagnostics | Prominent readiness shield | Optional Help action; errors still lead to diagnosis |

No schema migration, dependency, account, cloud service, writable API or
low-level fingerprint switch is introduced. The same browser-data directories,
credentials, seeds and trusted process ownership remain authoritative. Runtime
checking, proxy preparation and Direct release gates are not weakened.

## What remains a hypothesis

The combination may differentiate NeAntik for local macOS users. It is not a
world-first claim. “Revolution” means substantially less user coordination in
this product, not a new fingerprint algorithm. We have not proved faster
Chromium page loads, guaranteed login persistence, universal anonymity or
zero failures. Tab restoration, encrypted portable backups and crash snapshots
require separate threat/consistency designs. Online reviews cannot replace
observing real users; follow-up should measure task completion on create,
connect, return and recover scenarios.

Verification results and release status belong to the cycle delivery record;
source implementation alone is not publication. Public binaries must bind a
reviewed exact merged commit and pass fresh Direct Distribution verification.
