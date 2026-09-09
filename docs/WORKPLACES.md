# NeAntik workplaces

Product direction: each part of your day has its own internet. The primary
object is a named, persistent workplace; the user returns to an activity rather
than managing browser process records.

## 0.5.0 candidate

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
candidate. Those require a separate runtime change and fresh fingerprint,
network, signing and runtime provenance evidence. Do not advertise them as done.

Automation should remove repeated setup while preserving explicit destination
and identity. Next experiments should measure time from intent to an existing
session, wrong-context actions, and steps needed to recover after interruption.
Any automatic routing proposal must be visible and reversible; unknown links
must not silently move between identities.

## Publication

README and CHANGELOG describe source capabilities until a notarized release is
published. The website hero change is source-only until the root-owned template
is deployed through its administrative installation procedure. The restricted
six-file release channel cannot upload executable Blade templates.
