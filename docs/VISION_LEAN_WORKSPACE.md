# Vision Lean Workspace

Research cut: 2026-08-30. This is a product-design note, not a feature-parity
claim. Vision is used as a reference for a clear list-first workflow; NeAntik
keeps local-only storage, native macOS controls and its existing safety model.

## Reference pattern

Vision's official profile documentation describes one table where the user can
see Start, profile name, proxy, status, tags and notes, while mass actions only
appear when a selection exists. Its folder documentation keeps traffic-source
organization in a left sidebar. Those two patterns reduce navigation between
the list and the frequent action without requiring Vision's accounts, teams,
cloud, billing, automation or configurable table system.

Sources:

- [Vision profile table](https://docs.browser.vision/profiles/overview)
- [Vision folders](https://docs.browser.vision/folders/overview)
- [Vision 3.6.2 profile sidebar](https://browser.vision/news/update-3-6-2)

## Twenty bounded candidates

| # | Candidate | Value | Cost / decision |
| --- | --- | --- | --- |
| 1 | Make the profile list the main workspace | More profiles and context fit without horizontal competition | Implemented |
| 2 | Move full detail into a native optional inspector | Detail stays one click away without being permanent chrome | Implemented |
| 3 | Add an adaptive table row on wide windows | Start, profile, status, route and context scan in one line | Implemented |
| 4 | Keep a compact row below the wide threshold | The 820x560 minimum remains usable | Implemented |
| 5 | Put Start/Stop at the left edge in the wide row | Matches the eye path and Vision's primary action | Implemented |
| 6 | Expose a three-dot action menu on every row | Edit/move/duplicate/archive/delete no longer depend on right-click | Implemented |
| 7 | Use a restrained green tint for create/start | Primary actions become visually stable; Stop stays red | Implemented |
| 8 | Show visible and running counts together | The operator sees workspace state before scanning rows | Implemented |
| 9 | Show status as a text-and-symbol capsule | State remains readable without color alone | Implemented |
| 10 | Show note and last-launch context in the wide row | Removes unnecessary inspector opens | Implemented |
| 11 | Shorten the visible search prompt while retaining its full accessible label | Faster visual parsing without reducing search scope | Implemented |
| 12 | Put first-profile onboarding in the main workspace | Empty state no longer depends on a hidden detail column | Implemented |
| 13 | Add selection-only Start/Stop, move and tag actions | Useful for real bulk work, but requires multi-selection state | Later P1 |
| 14 | Add a small density switch: comfortable/compact | Helpful above roughly 30 profiles; validate demand first | Later P1 |
| 15 | Add inline note editing from the row menu | Saves a modal round trip; preserve note validation and privacy | Later P1 |
| 16 | Add inline folder/tag assignment | Useful if bounded to existing folders and tags | Later P1 |
| 17 | Add drag-and-drop into folders | Natural on macOS, but needs keyboard and undo parity | Later P1 |
| 18 | Add a Running scope beside Active/Pinned/Archive | Cheap projection after usage evidence confirms demand | Later P1 |
| 19 | Add a local redacted proxy-health history | Diagnostic value, but it adds persistence and retention rules | Separate P2 |
| 20 | Add a native multi-window arrangement command | Useful for many simultaneous sessions; separate window-state project | Separate P2 |

## Implemented slice

The current slice implements candidates 1-12 as one layout change. It does not
change the profile schema, browser identity, proxy policy, Keychain behavior,
launch arguments, Chromium runtime or release artifacts. It adds no package,
bitmap, web view or background service.

The wide row keeps fixed budgets for actions and status while profile, route
and context columns share the remaining width. It falls back to a compact row
below the reviewed threshold. The optional inspector uses native SwiftUI and
the existing `ProfileDetailView`; no second representation of profile data was
created. Context menus remain available as a redundant expert path, while the
visible row menu becomes the discoverable path.

## Acceptance gate

- 820x560, 1100x720 and 1600x1000 render in light and dark modes;
- keyboard focus, profile selection and existing command menus remain intact;
- Start/Stop, edit, move, duplicate, pin, archive and delete reuse the existing
  command closures;
- no secret value enters the row, search or accessibility label;
- no Chromium resource or third-party dependency changes;
- full Swift, Python, privacy, ARM64 and signed-runtime live gates pass before
  merge.

## Release boundary

This dated source iteration was delivered in immutable GitHub release
`0.3.22 (25)`. A later release must use a new version/build and pass the full
Direct Distribution workflow from one exact merged commit.
