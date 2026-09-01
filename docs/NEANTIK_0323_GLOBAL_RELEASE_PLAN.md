# NeAntik 0.3.23 global audit and Direct release plan

Plan cut: 2026-09-01. This is the active 100-point verification and delivery
plan for `0.3.23 (26)`. It replaces feature-count thinking with a bounded
sequence: prove current truth, improve the daily path, simplify ownership,
verify the exact merged commit, and publish only immutable signed artifacts.

## Execution outcome

Items 1–95 and 100 are complete. GitHub Release `v0.3.23` is immutable and
points to exact merged commit
`fdc520391c58a76622936519ca38b382f629fc47`; its four assets were re-downloaded
and verified. Items 96–99 are safely blocked before publication because the
dedicated AffPapa deploy key is absent. The exact six-file site directory is
ready locally, and the public website remains on `0.3.22 (25)` until the
restricted wrapper transaction can run.

## A. Baseline and boundaries

1. Pin the exact `origin/main` commit before edits.
2. Confirm the worktree contains no unrelated changes.
3. Record the current public GitHub release and asset digests.
4. Record the live site version, build, downloads and displayed SHA-256.
5. Run the GitHub-only release doctor.
6. Verify the external Developer ID provisioning profile against the exact certificate.
7. Verify the Keychain notarization profile without exposing credentials.
8. Reconcile the current project map, roadmap, changelog and historical 100-point plan.
9. Separate remaining P0/P1 work from rejected cloud, RPA, marketplace and telemetry scope.
10. Keep public `0.3.22 (25)` unchanged until every candidate-bound gate passes.

## B. Live interface baseline

11. Build the isolated development application from the pinned source tree.
12. Launch with a private temporary data root and disabled real Keychain mutations.
13. Review the empty workspace at the 820x560 minimum.
14. Review the ordinary wide workspace.
15. Review light appearance.
16. Review dark appearance.
17. Verify Create remains the primary action.
18. Verify Start/Stop remains visible and state-specific.
19. Verify notes are visible and editable without opening advanced fingerprint settings.
20. Verify settings and shortcut reference are discoverable from native menus.

## C. Daily-path usability

21. Create a Direct profile using only the keyboard where practical.
22. Create a profile with an optional note and confirm the note is visible in the list.
23. Edit a note from the dedicated note command and confirm focus returns safely.
24. Verify Quick Create issues a fresh permanent local profile and readable unique name.
25. Verify profile search indexes only safe display values.
26. Verify Escape clears search and then returns focus to the list.
27. Verify profile commands remain disabled under every sheet and alert.
28. Verify multi-selection actions appear only after selection.
29. Verify destructive actions remain explicit and confirmed.
30. Remove or simplify any control that does not reduce ambiguity in the frequent path.

## D. Swift ownership and cleanup

31. Inventory every Swift owner by lines and bytes.
32. Keep source budgets fail-closed and lower them when extraction succeeds.
33. Extract ContentView-only request and presentation state from the oversized view owner.
34. Extract the cached profile-list resolver from the SwiftUI composition file.
35. Keep extracted state free of network, filesystem and Keychain side effects.
36. Remove duplicate or unreachable view helpers proven unused by compiler and search evidence.
37. Inspect forced casts, forced tries, fatal errors and synchronous main-thread calls.
38. Preserve required NSCoder unavailability and verified CoreFoundation type checks.
39. Preserve legacy profile, path, Unicode/ZWJ and Keychain migrations that still have tests.
40. Update the project map to match final source ownership.

## E. Product and data safety

41. Keep the embedded runtime as the only production runtime candidate.
42. Keep proxy credentials out of command-line arguments and profile JSON.
43. Keep direct-profile saves free of unnecessary Keychain operations.
44. Keep all persisted strings bounded by characters and UTF-8 bytes.
45. Keep profile writes atomic and rollback-safe around credential failures.
46. Keep process ownership fail-closed across PID reuse and manager crashes.
47. Keep proxy preparation fresh before every proxied browser session.
48. Keep release fingerprint evidence unreachable from ordinary UI.
49. Keep diagnostics bounded, redacted and free of exact private paths.
50. Keep product telemetry and in-app updater code absent.

## F. Repository and supply-chain security

51. Scan the current tree for private keys and known service-token formats.
52. Scan every reachable Git commit without printing matched secret contents.
53. Scan historical filenames for `.env`, signing keys and provisioning profiles.
54. Scan for assigned mnemonic or seed-recovery phrases.
55. Query GitHub secret-scanning alerts before and after merge.
56. Verify Actions are pinned to immutable commit SHAs.
57. Verify workflows have read-only default permissions.
58. Verify public workflow dependency closure.
59. Verify runtime source provenance, candidate lock and license notices.
60. Refuse history rewriting unless a real secret is positively identified.

## G. Automated quality and performance

61. Run targeted tests for every modified Swift owner.
62. Run responsive render tests at minimum and wide sizes.
63. Run the complete native Swift test suite outside restricted networking.
64. Run the complete Python regression suite.
65. Run the AffPapa release regression suite.
66. Run the native ARM64 release build.
67. Run source/privacy/manual-update/localization contracts.
68. Run fingerprint corpus, Apple tuple, issuance and patch-manifest contracts.
69. Measure cold/warm manager startup and idle manager CPU/RSS.
70. Measure exact installed manager, runtime, compliance and total bundle size.

## H. Release-source closure

71. Move all `Unreleased` entries into `Direct 0.3.23 (26)`.
72. Ensure README Russian and English describe one consistent source candidate.
73. Ensure Info.plist remains exactly `0.3.23 (26)`.
74. Ensure the runtime lock and embedded runtime version agree.
75. Commit only reviewed source, tests and documentation.
76. Push without force-push.
77. Create one PR into `main`.
78. Wait for every PR GitHub check.
79. Merge normally and record the exact merge commit.
80. Wait for post-merge CI on that exact commit and compare source and merge trees.

## I. Signed candidate

81. Build exactly one candidate from the immutable merge commit.
82. Use the authorized Developer ID Application certificate.
83. Embed and revalidate the external Developer ID provisioning profile.
84. Generate fresh protected A→B→A evidence for the exact candidate.
85. Sign the manager, runtime, helpers and nested code with timestamp and hardened runtime.
86. Submit ZIP to Apple notarization and require Accepted.
87. Build DMG from the exact verified ZIP bytes.
88. Submit DMG to Apple notarization and require Accepted.
89. Staple and validate both distributable forms where supported.
90. Pass `codesign`, Gatekeeper, architecture, privacy and local-policy verification.

## J. Immutable publication and live verification

91. Create immutable Git tag `v0.3.23` at the exact merge commit.
92. Publish DMG, ZIP and canonical SHA-256 sidecars in GitHub Releases.
93. Re-download every GitHub asset and compare size and SHA-256.
94. Prepare exactly six AffPapa release-directory files from the tagged source.
95. Run the release wrapper `prepare` gate without manual server edits.
96. Publish the site only through `neantik-affpapa-release publish` when its restricted key is available.
97. Re-download live DMG and ZIP and repeat SHA-256, signing, stapling and Gatekeeper checks.
98. Verify live HTML, `release.json`, `content.json`, version, build, links and checksums.
99. Perform desktop and narrow-browser click QA for both download actions.
100. Repeat the repository/GitHub secret audit and keep `0.3.22 (25)` public on any mismatch.

## Stop rule

Any failed test, signature, certificate, notarization, stapling, Gatekeeper,
hash, GitHub, site, browser or secret gate stops public activation. Direct
release work never uses App Store Connect, a mutable branch name as input, or
manual SSH/SCP/SFTP/rsync/server editing.
