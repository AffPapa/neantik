# Lean UX research and selected follow-up

Research date: 2026-09-07. Scope: documented profile-manager workflows in
twelve products, selected public review signals, prior NeAntik research and
current native UI source. This is not an installation or performance comparison,
a security certification, or evidence that a new public release exists.

## Product rule

Optimize the existing path: find a profile, understand its state and route,
launch it, return to its window, and stop it safely. Prefer fewer ambiguities
and reliable native controls over adding competitor subsystems.

## Twelve-product matrix

Vendor documentation establishes intended behavior, not independently verified
anonymity, reliability or speed. Links below were checked during this review.

| Product and primary source | Useful pattern | NeAntik decision |
| --- | --- | --- |
| [Vision](https://docs.browser.vision/profiles/overview) | Row launch beside name, proxy, status, tags and notes; selection-driven mass actions | Keep existing list-first workflow and stable launch position; do not add a column designer |
| [Dolphin](https://docs.dolphin-anty.com/en/interface-dolphin-anty/application-interface-dolphin-anty) | Search, filters and bulk operations around profiles; separate automation/team systems | Preserve clear local profile navigation; do not copy the SaaS sidebar |
| [GoLogin](https://gologin.com/docs/browser-profiles/profile-management/notes-and-tags) | Direct note/tag editing and filtering | Improve discoverability and draft safety; no rich-text editor or cloud semantics |
| [Multilogin](https://multilogin.com/help/en_US/start/how-to-create-and-launch-a-profile-in-multilogin-x) | General and Proxy setup, with optional fingerprint configuration and recommended coherent defaults | Keep the short default path and advanced disclosure; no independent fingerprint toggles |
| [AdsPower](https://help.adspower.com/docs/editing) | Quick metadata editing and selection-based bulk edits | Keep frequent metadata actions accessible; do not make every field inline-editable |
| [Octo](https://docs.octobrowser.net/en/profiles/profiles-page/) | Profile list with organization, search and related folder/tag/keyboard workflows | Improve scanability without adding parallel organization concepts |
| [Incogniton](https://docs.incogniton.com/browser-and-browser-profiles/managing-browser-profiles/tagging-profiles-with-markers) | Apply markers and filter profiles by tags | Existing tags cover the need; no second marker system |
| [Kameleo](https://help.kameleo.io/article/72-default-profile-settings) | Defaults reduce repeated profile setup | Preserve safe defaults; do not silently inherit proxy credentials |
| [MoreLogin](https://support.morelogin.com/en/articles/10137634-browser-management) | Row-level launch and convenient profile management | Keep existing direct actions; no cloud-phone or diagnostic-dashboard subsystem |
| [Undetectable](https://docs.undetectable.io/ru/mass-management/profile-manager/) | Bulk lifecycle, organization and editing operations | Retain bounded contextual actions; no permanent mass-operation toolbar |
| [Linken Sphere](https://ls.app/docs/sessions/hotkeys) | Organized keyboard commands for manager workflows | Keep discoverable native commands; do not copy destructive hotkeys |
| [SessionBox](https://sessionbox.io/features) | Profile switching within one browser window | Useful contrast, not the same architecture; use existing window-focus action rather than change isolation model |

### Source consistency

Fresh Octo documentation includes a Working with folders section. A competing
vendor's comparison article says Octo lacks folders. The primary documentation
takes precedence; the contradictory comparison is not used to establish a
feature gap.

## Review signals

[GoLogin reviews](https://www.trustpilot.com/review/gologin.com) include both
praise for clear profile management and individual complaints about slowness,
crashes and session persistence. These observations support testing predictable
state transitions and preservation, not claiming comparative performance.

[Octo reviews](https://www.trustpilot.com/review/octobrowser.net) include praise
for a clean interface and dated discussion of folder/tag convenience. Reviews
from different versions cannot establish whether a feature is currently absent.

Public reviews are self-selected and may be solicited; they are qualitative
prioritization signals, not representative surveys, defect rates or proof of
fingerprint quality. No vendor ranking is inferred.

## Existing implementation checked

Prior research reviewed:

- `COMPETITOR_UX_RESEARCH_2026-09-01.md`
- `UX_SIMPLICITY_REVIEW_2026-09-05.md`
- `UNIFIED_MINIMAL_UX.md`

Current source inspection confirms dedicated note editing with draft safeguards,
folder/tag organization, structured search help, contextual actions, Settings
shortcut search, a shortcut reference and a disclosed density preview. These
are not new feature proposals or newly completed work in this research pass.

## Selected bounded improvements

The implementation track selected five native clarity/accessibility changes.
This table defines intended acceptance, not a claim that all tests or release
gates have already passed.

| ID | Change | Acceptance |
| --- | --- | --- |
| L01 | Keep inspector dismissal available | The existing inspector control remains enabled for dismissal after an empty search, preserving profile state and list context |
| L02 | Correct and simplify search help | Visible explanation matches fields actually searched; credentials are not implied to be searchable; examples remain usable |
| L03 | Give Settings shortcut-search control a consistent hit target | Magnifying-glass action has an explicit target comparable to adjacent clear action, a meaningful accessible name and unchanged Cmd+F behavior |
| L04 | Improve note accessibility | Assistive technology can distinguish adding from editing a note and identify the affected profile without requiring a hover |
| L05 | Expose batch selection semantically | Selected rows communicate selection through the appropriate accessibility trait as well as their existing text/value; toggling remains reversible |

All five should reuse existing operations. They require no runtime update,
new persistence schema, dependencies, cloud service or additional settings.
Check them with focused regressions and actual native UI interaction, including
keyboard navigation and compact/light/dark layouts where applicable.

## Deferred or rejected

Do not add rich-text notes, configurable columns, another marker/status model,
cloud teams, RPA, cookie robots, marketplaces, mobile farms, fingerprint sliders
or an anonymity score merely to match a feature list. Custom global shortcuts
would require conflict and safety design and are not part of this slice.

Potential wrapping of long proxy-check result text beside Retry should first be
reproduced at the minimum window size. It is an inspection hypothesis, not a
confirmed defect. Performance changes need measurements rather than a target
percentage or deletion of safeguards.

## Evidence limits and release boundary

The fresh Vision screenshot endpoint timed out; Dolphin's linked interface GIF
was unsupported by the web viewer. Documentation and its descriptions of the
interface were inspected, but this is not a claim that fresh screenshots of all
twelve applications were visually validated. Incogniton's page open failed;
its indexed official documentation provided the tagging observation.

Competitors were not installed or exercised with real profiles. NeAntik source
inspection is not end-to-end UI certification. Implementation, native tests,
render/click checks and Direct Distribution release verification must be recorded
separately. Public version/download claims must remain tied to actually verified
signed, notarized, stapled and published artifacts, not this research document.
