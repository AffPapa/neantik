# NeAntik Profile Library UX

Research date: August 30, 2026.

## Outcome

The daily job stays short and local:

> create a profile -> add a note or proxy when needed -> see the route and
> state -> launch.

NeAntik adopts the legible profile-library pattern without adopting the cloud
workspace, team, billing, automation, proxy marketplace or API-dashboard
surfaces that make competing products dense.

## Evidence

The recurring product pattern was checked against official documentation for
[Dolphin Anty](https://docs.dolphin-anty.com/en/interface-dolphin-anty/application-interface-dolphin-anty),
[Vision](https://docs.browser.vision/profiles/overview),
[GoLogin](https://support.gologin.com/en/articles/14356784-profile-fields),
[AdsPower](https://help.adspower.com/docs/editing),
[Multilogin](https://multilogin.com/academy/multilogin-new-ui-update/) and
[Octo Browser](https://docs.octobrowser.net/en/profiles/profiles-page/).
All make the profile list, search, state, proxy and launch action central.

Independent review pages for
[GoLogin](https://www.g2.com/products/gologin-gologin/reviews),
[AdsPower](https://www.capterra.com/p/228046/AdsPower/),
[Dolphin Anty](https://www.trustpilot.com/review/dolphin-anty.com),
[Multilogin](https://www.g2.com/products/multilogin/reviews),
[Octo Browser](https://www.capterra.com/p/10002105/Octo-Browser/reviews/)
and [Vision](https://www.trustpilot.com/review/browser.vision) repeatedly
praise short setup, clear profile lists and fast launch, while complaints
concentrate on crashes, session loss, slow launches, forced migrations and
advanced-settings overload. These are qualitative signals rather than market
statistics: samples are self-selected, Vision has a small review set, some
Capterra entries are vendor-referred or incentivized,
[Octo invites customers to review](https://www.trustpilot.com/review/octobrowser.net),
and [Trustpilot records an integrity warning for Multilogin](https://www.trustpilot.com/review/multilogin.com).

Apple's current [Lists and tables](https://developer.apple.com/design/human-interface-guidelines/lists-and-tables),
[Buttons](https://developer.apple.com/design/human-interface-guidelines/buttons)
and [Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars)
guidance supports the same native direction: concise scannable rows, text when
it is clearer than an icon, one visually prominent action, familiar symbols
and an automatically collapsible sidebar.

## Adopted

- One visible ordinary Create action; bulk proxy creation lives in `More`.
- Name, optional note and optional proxy before organization or appearance.
- Text plus symbol for profile state and route; color is supplemental.
- One-line local note preview and a labelled launch/stop button in every row.
- Standard SwiftUI/AppKit controls, SF Symbols and macOS shortcuts.

## Deliberately excluded

- Accounts, cloud sync, teams, roles and sharing.
- RPA, synchronizers, scripts and browser automation.
- Billing, referrals and proxy marketplaces.
- Rich-text notes, custom dashboards and configurable table builders.
- New dependencies, bitmap UI packs, web views or background network calls.

## Size boundary

The interface is not the cause of the distribution size. In the published
0.3.21 package, the native manager is about 8.7 MiB, while the bundled
Chromium runtime and its required compliance material account for almost the
entire 432 MiB installed application. With the same compiler and release
flags, this branch changes the manager from 9,167,624 to 9,225,960 bytes:
+58,336 bytes (0.636%), or 0.0129% of a 432 MiB application. Runtime or locale
pruning is a separate security, licensing and Direct Distribution project; it
must not be mixed into a manager-only UX change.
