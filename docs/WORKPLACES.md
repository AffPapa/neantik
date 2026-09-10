# NeAntik workplaces

Product direction: each part of your day has its own internet. The primary
object is a named, persistent workplace; the user returns to an activity rather
than managing browser process records.

## Published 0.5.0 behavior

- Home lists pinned and recent active profiles, capped at 24. Search matches
  local names, tags and notes; a single match can be opened with Return.
- Open starts the existing guarded launch. Continue activates a verified browser
  process. Stop remains explicit in the catalog. Failed activation never launches
  a duplicate browser.
- Command-1 returns home; Command-2 opens the existing full catalog. The catalog
  retains folders, archive, diagnostics and advanced operations.
- A native menu offers up to eight pinned/recent workplaces. Its label shows the
  active workplace only when the process identity and on-disk lease agree.
- Menu navigation is in-process, consumed once, and disabled during modal work.
  The menu is not inserted in the automated fingerprint release audit.

A workplace is an existing BrowserProfile. This change introduces no migration,
new persisted field, proxy assignment, credential copy, identity rotation,
background browsing, hosted account or external AI service.

## Architectural next step

The Chromium window remains independent. A shared browser shell, embedded
workplace switcher and browser-internal context label are not delivered by this
release. Those require a separate runtime change and fresh fingerprint,
network, signing and runtime provenance evidence. Do not advertise them as done.

Automation should remove repeated setup while preserving explicit destination
and identity. Next experiments should measure time from intent to an existing
session, wrong-context actions, and steps needed to recover after interruption.
Any automatic routing proposal must be visible and reversible; unknown links
must not silently move between identities.

## Published 0.5.1 everyday-work refinement

The same home now covers first run, ordinary work and recovery. Existing guarded
one-click onboarding remains; the empty state links directly to the archive.
Home search has a clear button and Escape behavior. The row menu offers pin,
edit, details and ordinary stop through the same command policies as the catalog.
A note or tags helps identify the workplace without exposing proxy endpoints.

The editor retains one stable draft identity and baseline while SwiftUI refreshes.
Closing an untouched form needs no confirmation. Real changes retain discard
protection. Runtime-unavailable and per-workplace unexpected-exit feedback show
what to do next; recovery does not automatically launch another browser.

Normal reopening of a previously launched workplace with the default about:blank
startup restores its own last tabs without appending another blank window.
A configured startup address, explicit override and fingerprint-audit launch
retain their explicit destinations. The user-data directory, credentials,
identity and proxy preflight are unchanged.

## Publication

These refinements are published in
[Direct 0.5.1 (31)](https://github.com/AffPapa/neantik/releases/tag/v0.5.1),
from source commit `a7ce19238bbd03f146e95aa215707e7db19ed31d`.
GitHub Releases is authoritative for downloadable files, SHA-256 and release
validation. The 0.5.0 downloads remain unchanged.
The [standalone landing](https://nevision-stats.iryadom.chatgpt.site/) provides
product and installation information. AffPapa updates are handled separately
by the owner; no portal deployment is part of this release.
