# NeAntik v4 readiness and optimization plan

Research cut: 2026-08-31. This plan continues the source-only v4 workspace
iteration. It does not create a public binary release. GitHub Releases and
`affpapa.org/neantik` remain on `0.3.21 (24)` until one exact merged commit
passes Developer ID signing, Apple notarization, stapling, Gatekeeper and the
full Direct Distribution transaction.

## Product thesis

NeAntik should remain a fast native local control panel for isolated browser
profiles. It adopts the profile-table clarity of Vision and Octo, the direct
profile actions of GoLogin, and the explicit proxy/runtime diagnostics of
Dolphin, AdsPower, Multilogin and Kameleo without copying their cloud account,
team, billing, marketplace, synchronizer or automation surfaces.

Current official documentation converges on five useful patterns:

- a list-first profile workspace with Start/Stop, status, tags, notes and proxy
  state ([Vision](https://docs.browser.vision/profiles/overview),
  [GoLogin](https://gologin.com/docs/browser-profiles/profile-management/notes-and-tags));
- safe defaults and warnings against inconsistent manual fingerprint changes
  ([Octo](https://docs.octobrowser.net/en/profiles/browser-profile-settings/),
  [Multilogin](https://multilogin.com/help/en_US/start/how-to-create-and-launch-a-profile-in-multilogin-x));
- proxy validation before launch
  ([AdsPower](https://help.adspower.com/docs/creating_browser_profiles),
  [Kameleo](https://help.kameleo.io/article/62-built-in-proxy-manager));
- explicit lifecycle and bulk operations
  ([Dolphin](https://docs.dolphin-anty.com/en/interface-dolphin-anty/application-interface-dolphin-anty),
  [Incogniton](https://docs.incogniton.com/));
- advanced systems kept outside the daily profile workflow.

## Verified baseline

- The v4 shell is already list-first, adaptive, keyboard-aware and local-only.
- `ContentView.swift` is 4,057 lines and is the largest UI maintenance risk.
- The local Dev app is about 565 MiB installed: about 509 MiB is the required
  Chromium framework, about 38 MiB is runtime compliance material and about
  16 MiB is the development manager binary. UI code is not the weight driver.
- The final open-source tree contains 435 files and no recognized secret
  material.
- The release doctor is blocked only by the absent out-of-repository deploy
  key; this source cycle must not work around that boundary.

## One hundred improvements and checks

Priority: P0 correctness/recovery, P1 daily workflow/performance, P2 bounded
follow-up. The current delivery slice is marked **NOW**.

### A. Launch and recovery correctness

1. **P0 NOW** Add one workspace readiness snapshot for runtime, storage, process and route state.
2. **P0 NOW** Show one overall verdict: Ready, Check, or Blocked.
3. **P0 NOW** Re-run all safe readiness checks without restarting NeAntik.
4. **P0 NOW** Show the exact running application name and bundle path.
5. **P0 NOW** Show the exact local data-root status without exposing individual profile paths.
6. **P0 NOW** Keep raw proxy credentials, observed IPs, seeds and BrowserData paths out of diagnostics.
7. **P0 NOW** Make every blocking readiness row include one next action.
8. **P0** Split launch into named runtime, storage, proxy, consistency and process stages.
9. **P0** Preserve one actionable failure for the exact failed stage.
10. **P0** Add a pre-launch available-space guard with a conservative threshold.

### B. macOS permission clarity

11. **P0 NOW** Explain that users select the installed `NeAntik.app`, not the nested runtime helper.
12. **P0 NOW** Provide a bounded Copy App Path action.
13. **P0 NOW** Provide a Reveal App action using the native Finder API.
14. **P0** Detect translocation and explain reinstall/move-to-Applications remediation.
15. **P0** Detect a read-only or unavailable application data root.
16. **P0** Link only to public supported System Settings panes.
17. **P0** Recheck after returning from System Settings.
18. **P1** Show the bundle identifier beside the app name for support cases.
19. **P1** Distinguish NeAntik manager permissions from Chromium website permissions.
20. **P1** Add a permission-focused troubleshooting article with screenshots.

### C. Process lifecycle and session safety

21. **P0** Add Dirty shutdown evidence for manager and profiles.
22. **P0** Model Closing, Data saved and Stopped as separate lifecycle phases.
23. **P0** Keep Force Stop separate and warn about session-data loss.
24. **P0** Detect stale lock files without trusting PID reuse.
25. **P0** Offer safe reconciliation after a manager crash.
26. **P1** Add a running strip with Focus, Stop and elapsed time.
27. **P1** Keep recovered/manual processes visually distinct from managed ones.
28. **P1** Add cancellation to launch preparation.
29. **P1** Bound concurrent profile launches.
30. **P1** Add deterministic process-state transition tests.

### D. Profile workspace simplicity

31. **P1** Keep one adaptive command row and one visually primary Create action.
32. **P1** Preserve All, Running, Attention and Never launched computed views.
33. **P1** Add a visible Details affordance without requiring a context click.
34. **P1** Keep Comfortable and Compact as the only density modes.
35. **P1** Add keyboard focus order tests for sidebar, list and inspector.
36. **P1** Add selection-only actions before multi-select.
37. **P1** Add non-destructive multi-select with a visible selected count.
38. **P1** Add atomic batch folder, tag, pin and archive changes.
39. **P1** Add Undo for metadata-only batch changes.
40. **P2** Add optional saved local views only after usage evidence.

### E. Creation and editing

41. **P1** Keep Name, Note and Direct/Proxy before advanced organization fields.
42. **P1** Add a restart-required preview for edits to a running profile.
43. **P1** Add searchable folder and tag pickers.
44. **P1** Rename Duplicate to Create similar and explain fresh identity/session data.
45. **P1** Add a Quick Create split menu limited to safe local templates.
46. **P1** Keep proxy parsing paste-first and local.
47. **P1** Consolidate repeated proxy explanations into one disclosure.
48. **P1** Preserve character and UTF-8 byte limits for legacy Unicode/ZWJ data.
49. **P1** Keep note warnings against passwords, API keys and seed phrases.
50. **P2** Add config-only import/export only after an allowlist threat model.

### F. Proxy workflow

51. **P0** Keep a fresh proxy preparation check before every proxied launch.
52. **P1** Present only the relevant Test, Retry or Edit action.
53. **P1** Show outcome, latency, country, timezone and check time without exact IP by default.
54. **P1** Add bulk-check totals and Retry failed.
55. **P1** Add drag-and-drop proxy text with preview and deduplication.
56. **P1** Make a failed manual test diagnostic, not permanent launch authority.
57. **P1** Expire stale proxy results visibly.
58. **P1** Add proxy-format examples beside the paste field.
59. **P2** Add a local proxy catalog backed by Keychain references only.
60. **P2** Add bounded rotation helpers only when the provider contract is explicit.

### G. Diagnostics and support

61. **P0 NOW** Add a compact native readiness center instead of another dashboard.
62. **P0 NOW** Make diagnostic copy deterministic, bounded and redacted.
63. **P0 NOW** Include app version/build and runtime state, never credentials or hashes.
64. **P0 NOW** Add pure projection tests for every readiness verdict.
65. **P1** Add a redaction preview before saving any future diagnostic bundle.
66. **P1** Add a bounded local activity timeline with explicit Clear.
67. **P1** Add Configured versus Observed environment comparison.
68. **P1** Keep a numeric anonymity or ban-avoidance score forbidden.
69. **P1** Add one-click opening of the existing per-profile environment inspector.
70. **P2** Add last-known-good snapshots only before migration or repair.

### H. Performance and application weight

71. **P0 NOW** Record deterministic installed-size component budgets.
72. **P0 NOW** Fail if manager/UI growth is confused with Chromium runtime growth.
73. **P1** Add cold and warm manager-start measurement scripts.
74. **P1** Keep the 10,000-profile projection performance gate.
75. **P1** Measure idle manager CPU and resident memory outside Chromium.
76. **P1** Measure Chromium cold and warm launch separately.
77. **P1** Compute profile size asynchronously and cancelably.
78. **P1** Show total disk use and largest profiles only on demand.
79. **P1** Keep runtime locales, licenses, notices, SwiftShader and crashpad unless evidence proves safe removal.
80. **P2** Investigate differential runtime updates as a separate signed-delivery project.

### I. Code health and testability

81. **P0 NOW** Move readiness projection and presentation out of `ContentView.swift`.
82. **P1** Split the profile list header, row and empty states by presentation responsibility.
83. **P1** Consolidate filter/status presentation logic.
84. **P1** Keep all domain decisions out of SwiftUI bodies.
85. **P1** Add file-size budgets for oversized Swift sources.
86. **P1** Preserve zero third-party package dependencies.
87. **P1** Add race-focused cancellation tests for launch and proxy tasks.
88. **P1** Add deterministic time providers for freshness and elapsed-time UI.
89. **P1** Add snapshot fixtures for light/dark and minimum/ordinary/wide widths.
90. **P1** Keep release-only evidence paths unreachable from ordinary UI.

### J. Accessibility, release and security gates

91. **P0 NOW** Give each readiness row a complete VoiceOver label and value.
92. **P1** Verify text-plus-symbol states without color dependence.
93. **P1** Verify Dynamic Type and long Russian text at 820x560.
94. **P1** Verify full keyboard use without a pointer.
95. **P0** Keep source/privacy/secret gates mandatory on every PR.
96. **P0** Require exact merged SHA as the only future release input.
97. **P0** Keep Developer ID, notarization, stapling and Gatekeeper as separate gates.
98. **P0** Keep GitHub Releases and the website unchanged on any mismatch.
99. **P0** Never use SSH, SCP, SFTP, rsync or manual server edits.
100. **P0** Re-download public artifacts and compare SHA-256 after any future publish.

## Current delivery gate

This source slice is complete only when:

1. readiness projection tests cover ready, warning, blocked and checking;
2. the visible center shows app, runtime, data storage, process and route rows;
3. Recheck changes the live snapshot without restarting the app;
4. copied diagnostics contain no paths to individual profiles, credentials,
   observed IPs, fingerprint values, hashes or seeds;
5. the size audit explains bundle components and enforces conservative budgets;
6. targeted and full Swift/Python/AffPapa/ARM64/source gates pass;
7. minimum, ordinary, wide, light and dark UI states are visually reviewed;
8. the exact PR commit passes every GitHub check before an ordinary merge;
9. public `0.3.21 (24)` and its versioned ZIP/DMG links remain unchanged.
