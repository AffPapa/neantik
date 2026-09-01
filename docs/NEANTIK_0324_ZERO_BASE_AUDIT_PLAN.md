# NeAntik 0.3.24 zero-base audit plan

Research cut: 2026-09-01. This is an evidence checklist, not a claim that any
application can be made impossible to compromise. Each track follows:

> evidence -> risk -> smallest justified change -> test -> release gate

The product boundary stays narrow: local Apple-Silicon profile management,
embedded Chromium, no account, cloud, telemetry, RPA, writable API, proxy
marketplace or arbitrary browser flags.

## Fifteen professional prompts

1. **macOS application-security engineer.** Audit the manager and every nested
   executable from an untrusted-input perspective. Trace filesystem, Keychain,
   process, URL, proxy and entitlement boundaries; prove validation and
   fail-closed behavior; propose only reproducible fixes and verify signed-app
   entitlements, hardened runtime and Gatekeeper.
2. **Offensive application red-team engineer.** Model attacks from a malicious
   profile file, symlink, replaced runtime, hostile environment, crafted proxy,
   stale PID and local loopback client. Build safe regression cases for every
   credible path and distinguish confirmed exploitability from speculation.
3. **software supply-chain security engineer.** Inventory source, SwiftPM,
   GitHub Actions, Chromium provenance, licenses and release inputs. Pin mutable
   dependencies, add automated analysis, verify exact hashes and reject any
   candidate that cannot be reproduced from one merged commit.
4. **secret-leak and repository-forensics engineer.** Scan the current tree,
   reachable history, Actions, releases and public pages for credentials,
   provisioning material, private keys, tokens, recovery phrases and metadata
   that should stay local. Never print a discovered secret; revoke first, then
   remove it from every public surface and prove the rescan is clean.
5. **senior Swift architect.** Map responsibilities, concurrency and state
   ownership; find dead code, unsafe casts, oversized owners, duplicate policy
   and accidental coupling. Refactor only independently testable seams and keep
   source-size budgets from increasing.
6. **Chromium integration and sandbox engineer.** Verify the exact embedded
   ARM64 runtime, signature chain, launch arguments, environment allowlist,
   profile isolation, sandbox and remote-debugging policy. Reject external
   runtime substitution and protected-flag injection.
7. **native macOS product designer.** Review the real app at default and minimum
   window sizes in light and dark modes. Make the frequent path—find/create,
   confirm route, Start/Stop—visually obvious with standard SwiftUI controls and
   no decorative dashboard.
8. **interaction designer.** Trace first profile, quick create, configured
   create, note edit, proxy import/test, launch, focus, stop, force stop, archive
   and recovery. Reduce ambiguity, preserve confirmation for destructive
   actions and ensure keyboard and pointer paths have equivalent outcomes.
9. **accessibility specialist.** Inspect the AX tree, names, values, hints,
   focus order, keyboard-only operation, contrast, reduced motion and Dynamic
   Type-like text pressure. Every icon-only fallback must retain a precise
   accessible name and minimum target.
10. **competitive UX researcher.** Compare current official workflows from
    Vision, Octo, Dolphin, GoLogin, Multilogin, MoreLogin, AdsPower, Kameleo,
    BitBrowser, Hidemyacc, NSTBrowser, Incogniton, Undetectable, VMLogin and
    SessionBox. Adopt recurring low-cost usability patterns, not product bloat.
11. **performance and binary-size engineer.** Measure cold/warm launch, list
    projection, memory, source budgets, manager size, runtime size and packaged
    artifacts. Attribute bytes before optimizing; never strip runtime security,
    locales required by policy, notices or release evidence.
12. **QA and reliability lead.** Derive deterministic unit, integration,
    responsive-render, live-manager and live-browser tests from each confirmed
    risk. Treat flaky, skipped or stale evidence as failure and preserve a
    single exact candidate.
13. **Direct Distribution release engineer.** Enforce version/build, changelog,
    exact merged commit, Developer ID, fresh A-to-B-to-A evidence, notarization,
    stapling, Gatekeeper, ZIP/DMG hashes, immutable GitHub assets and post-upload
    re-download verification. Never use App Store Connect.
14. **GitHub security administrator.** Audit Actions permissions, immutable
    action references, CodeQL, Dependabot, secret scanning, push protection,
    branch protection and release immutability. Apply the strongest settings
    compatible with a single-maintainer repository and prove required checks.
15. **technical writer and safety communicator.** Keep README, changelog,
    security policy, project map, GitHub Release and website aligned with the
    shipped binary. Explain local storage, proxy-secret handling and limits
    without promising anonymity, invisibility or an unhackable product.

## One hundred audit and improvement checks

### Repository, secrets and supply chain

1. Verify the exact clean source commit and public release commit.
2. Scan tracked filenames for `.env`, keys, profiles, wallets and backups.
3. Scan the current tree for recognized provider-token formats.
4. Scan every reachable Git blob without printing matched values.
5. Scan historical filenames for sensitive material.
6. Check GitHub secret-scanning alerts.
7. Check Dependabot alerts.
8. Enable non-provider secret patterns when supported.
9. Enable secret validity checks when supported.
10. Keep push protection enabled.
11. Verify no provisioning profile is tracked.
12. Verify no notary credential or API private key is tracked.
13. Verify no seed/recovery phrase is present in public material.
14. Verify SwiftPM has no undeclared third-party dependency.
15. Pin every GitHub Action to a full commit SHA.
16. Require SHA pinning in repository Actions settings.
17. Give workflows explicit least-privilege permissions.
18. Add CodeQL for Swift and Python.
19. Add Dependabot updates for GitHub Actions.
20. Protect `main` from force pushes and deletion.

### macOS and application security

21. Verify atomic profile metadata writes.
22. Reject symlinked metadata reads and writes.
23. Verify descriptor/path identity before and after reads.
24. Bound all user-controlled profile strings and collections.
25. Permit only HTTP/HTTPS start URLs without embedded credentials.
26. Parse proxy input locally before any network request.
27. Keep proxy passwords out of profile JSON and process arguments.
28. Store proxy passwords as `WhenUnlockedThisDeviceOnly` Keychain items.
29. Use the exact application Keychain access group.
30. Compensate Keychain mutations when metadata persistence fails.
31. Launch the browser without a shell.
32. Resolve only the declared embedded runtime.
33. Verify runtime ownership, architecture and signature before launch.
34. Pass only an explicit environment allowlist to Chromium.
35. Strip protected Chromium flags from inputs.
36. Keep the normal browser sandbox enabled.
37. Restrict diagnostic remote debugging to a fresh loopback-only audit.
38. Bind local diagnostic services only to loopback.
39. Reject stale, foreign and ambiguous process identities.
40. Signal only a process proven to belong to the selected profile.
41. Bound graceful stop and require confirmation for force stop.
42. Verify no distribution executable has `get-task-allow`.
43. Verify no distribution executable permits DYLD environment injection.
44. Inspect manager and runtime entitlements for unnecessary capabilities.
45. Validate every forced CoreFoundation bridge before casting.
46. Keep redacted diagnostics free of paths, credentials and profile contents.
47. Keep notes explicitly plaintext and warn against secrets.
48. Confirm deleted BrowserData uses a recoverable Trash path.
49. Confirm credential cleanup is retryable after partial deletion.
50. Document residual local-admin, compromised-OS and upstream-runtime risk.

### Architecture, correctness and performance

51. Inventory every Swift source owner and test owner.
52. Reject TODO/FIXME/HACK debt in production sources.
53. Review `fatalError` and unchecked-sendable uses individually.
54. Keep UI state separate from persistence and launch policy.
55. Keep profile projection deterministic and side-effect free.
56. Keep process lifecycle ownership in one subsystem.
57. Keep release-only fingerprint evidence out of daily UI paths.
58. Split large files only at independently testable seams.
59. Do not raise source line or byte budgets.
60. Avoid formatter-only churn across the established style.
61. Run all four isolated Swift test shards.
62. Run every Python regression test.
63. Run AffPapa release regression tests.
64. Run the optimized native ARM64 build.
65. Run open-source publication-boundary checks.
66. Run privacy and manual-update contracts.
67. Run runtime patch-manifest and notices checks.
68. Run public fingerprint corpus and Apple tuple checks.
69. Measure manager cold and warm launch.
70. Measure manager, runtime, compliance and packaged sizes separately.

### Interface, usability and accessibility

71. Make Search visibly describe profile and note discovery.
72. Keep the common Create action visible as text at normal width.
73. Keep Filters visible as text at normal width.
74. Prevent toolbar controls from expanding into empty pills.
75. Keep Start/Stop in the same left-side location in both layouts.
76. Rename the action column to describe selection and launch.
77. Rename the context column to describe note and last launch.
78. Keep route state readable without opening the inspector.
79. Keep the optional note visible during profile creation.
80. Keep the dedicated note editor reachable by pointer and keyboard.
81. Preserve one-click quick Direct creation behind a disclosed choice.
82. Preserve the full configured-profile editor as the primary Create action.
83. Keep bulk operations contextual to explicit selection.
84. Keep destructive actions textual, red and confirmed.
85. Keep proxy credentials masked and in Keychain.
86. Keep advanced configuration collapsed below the frequent fields.
87. Verify keyboard commands are disabled while any modal is active.
88. Verify Escape clears search before leaving focus.
89. Verify every icon-only fallback has an accessibility label.
90. Verify focus order and keyboard-only completion of the frequent path.
91. Render the actual root view at 820x560.
92. Render the actual root view at a normal wide size.
93. Check compact and comfortable row density.
94. Check light and dark appearances.
95. Check empty, populated, selected, running, error and archived states.
96. Click through create, note, proxy, launch, focus, stop and inspector flows.

### Direct release and public verification

97. Run `neantik-affpapa-release doctor` immediately before release work.
98. Build one exact merged commit with Developer ID, fresh evidence,
    notarization, stapling and Gatekeeper acceptance.
99. Upload immutable ZIP/DMG plus SHA-256 files and re-download all assets.
100. Verify hashes, Gatekeeper, release page, website version and exact download
     links, then repeat the secret-alert audit; stop publication on any mismatch.

## Accepted scope for this cycle

- Compact, visibly labelled list controls at normal width.
- Clearer search and table-header language.
- CodeQL and GitHub Actions dependency maintenance.
- Stronger repository settings and required checks after the workflow exists.
- A safety explanation beside the validated CoreFoundation bridge.
- Full source, test, ARM64, signed-candidate and live-browser evidence.

The recurring competitor patterns already present—folders, tags, notes,
structured search, explicit Start/Stop, quick create, contextual bulk actions
and a running-profile strip—remain. Cloud accounts, teams, RPA, rich-text
secret notes, arbitrary flags, column builders and marketplaces remain out of
scope because they add attack surface and binary/product weight without making
the frequent local workflow clearer.
