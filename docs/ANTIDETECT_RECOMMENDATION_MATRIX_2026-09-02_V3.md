# NeAntik recommendation matrix v3

Research cut: 2026-09-02. The baseline is exact merged commit
`4c3b0b1c48f64e438d220c32cc9bae6f25094254`. Three independent read-only
tracks produced 124 raw candidates; this document deduplicates them against
the current product into exactly 100 recommendations. `SELECT` marks the 25
items chosen for this source iteration, not a public binary release.
Machine-checked SELECT-to-code-to-test traceability lives in
`ANTIDETECT_RECOMMENDATION_TRACEABILITY_2026-09-02_V3.json`.

Weight `0` means no new dependency, runtime or bundled asset. `T` means a
small bounded local text/JSON sidecar. Effort is `XS/S/M/L`.

## Official source index

1. [Vision](https://docs.browser.vision/profiles/overview)
2. [Dolphin Anty](https://docs.dolphin-anty.com/)
3. [GoLogin](https://support.gologin.com/en/articles/14356784-profile-fields)
4. [Multilogin](https://multilogin.com/help/en_US/multilogin-x-top-features)
5. [AdsPower](https://help.adspower.com/docs/personal_settings)
6. [Octo Browser](https://docs.octobrowser.net/en/profiles/profiles-page/)
7. [Incogniton](https://docs.incogniton.com/browser-and-browser-profiles/launch-a-browser-profile/browser-doesnt-launch)
8. [MoreLogin](https://support.morelogin.com/en/articles/10137634-browser-management)
9. [Kameleo](https://developer.kameleo.io/concepts/profiles/)
10. [Hidemyacc](https://docs.hidemyacc.com/hidemyacc-3.0-features/edit-restore-profile-data/profile-history)
11. [Undetectable](https://docs.undetectable.io/working-with-profiles/create-and-run/)
12. [Linken Sphere](https://ls.app/docs/sessions/creating-and-launching-session)
13. [GenLogin](https://docs.genlogin.com/group-profiles/local-and-cloud-profiles)
14. [NSTBrowser](https://docs.nstbrowser.io/guide/getting-started/quick-start.html)
15. [DICloak](https://help.dicloak.com/category-en/)
16. [BitBrowser](https://doc.bitbrowser.net/help1/browser-profiles/features-and-functions)
17. [VMLogin](https://www.vmlogin.us/help/fingerprint/vmlogin-details.html)
18. [ixBrowser](https://www.ixbrowser.com/guide)
19. [Lalicat](https://www.lalicat.com/browser-profile-operations)
20. [ClonBrowser](https://www.clonbrowser.com/help/)
21. [WADE](https://docs.wade.is/api/launch/start_profile/)
22. [MuLogin](https://www.mulogin.com/doc/en/?cat=13)
23. [SessionBox](https://sessionbox.frontkb.com/en)
24. [Ghost Browser](https://support.ghostbrowser.com/article/321-workspaces)
25. [Maskfog](https://help.maskfog.com/?lang=en&p=370)
26. [Hubstudio](https://support-orig.hubstudio.cn/)
27. [1Browser](https://1browser.com/antidetect-browser/)
28. [FlashID](https://docs.flashid.app/api-reference/tags)
29. [AntBrowser](https://www.antbrowser.com/es/)
30. [Camoufox](https://camoufox.com/python/usage/)

Official documentation establishes product patterns, not comparative quality.
G2, Trustpilot and Reddit were used only as directional signals about
complexity, regressions and resource use; they are not evidence that a feature
works or that NeAntik is better.

## Ranked matrix

| ID | Recommendation | Value | Effort | Weight | Decision | Evidence |
|---|---|---:|---:|---:|---|---|
| ND3-001 | Enforce proxy-password bounds at every Keychain read/write boundary | H | XS | 0 | SELECT | Security audit |
| ND3-002 | Read process-lock files through one bounded stable descriptor | H | S | 0 | SELECT | WADE + code audit |
| ND3-003 | Read proxy-health state through a bounded no-follow descriptor | H | S | 0 | SELECT | Code audit |
| ND3-004 | Version the profiles document while retaining a legacy-array decoder | H | M | 0 | SELECT | Kameleo + code audit |
| ND3-005 | Replace the 512 MiB profile-metadata ceiling with a realistic safe budget | H | XS | 0 | SELECT | Performance audit |
| ND3-006 | Bound recovery files by age, count and aggregate bytes | H | M | 0 | SELECT | Hidemyacc + code audit |
| ND3-007 | Add a non-destructive deep storage readiness self-test | H | M | 0 | SELECT | Incogniton + code audit |
| ND3-008 | Read runtime metadata through a bounded stable descriptor | H | S | 0 | SELECT | Camoufox + code audit |
| ND3-009 | Ask how to quit when managed browsers are still running | H | M | 0 | SELECT | Multilogin |
| ND3-010 | Classify the last browser exit without persisting PID, args or paths | H | S | T | SELECT | Dolphin reviews + code audit |
| ND3-011 | Emit deterministic top-path and delta evidence in the app-size audit | M | S | 0 | SELECT | AdsPower + Camoufox |
| ND3-012 | Distinguish empty folder, no search result and filtered-empty states | H | S | 0 | SELECT | Vision + UX audit |
| ND3-013 | Give the folder picker a visible keyboard selection model | H | S | 0 | SELECT | Native macOS UX |
| ND3-014 | Jump from a bulk-import error to the exact invalid source line | H | M | 0 | SELECT | GoLogin + UX audit |
| ND3-015 | Keep safe profile actions consistent across row, menu and inspector | H | S | 0 | SELECT | Vision + MoreLogin |
| ND3-016 | Put Start, Stop, Focus and Edit in the profile-detail header | H | M | 0 | SELECT | Multilogin + Octo |
| ND3-017 | Render warnings through one semantic high-contrast notice component | H | S | 0 | SELECT | Accessibility audit |
| ND3-018 | Explain a runtime lookup that takes unusually long and offer safe retry | H | S | 0 | SELECT | Incogniton |
| ND3-019 | Add a native show/hide sidebar affordance for minimum-width work | M | S | 0 | SELECT | Vision + native macOS UX |
| ND3-020 | Show the visible result count after search and filters | M | XS | 0 | SELECT | GoLogin + Vision |
| ND3-021 | Explain when a filter change clears batch selection | M | XS | 0 | SELECT | UX audit |
| ND3-022 | Keep an explicit row-level proxy-test progress state | M | XS | 0 | SELECT | MoreLogin |
| ND3-023 | Confirm before a file replaces already pasted proxy input | H | S | 0 | SELECT | Data-loss UX audit |
| ND3-024 | Add concise VoiceOver custom actions to every profile row | H | S | 0 | SELECT | Accessibility audit |
| ND3-025 | Let the command row compact through `ViewThatFits` | M | S | 0 | SELECT | Vision + UX audit |
| ND3-026 | Preview old/new runtime version and hash before a migration | H | M | 0 | BACKLOG | AdsPower + Kameleo |
| ND3-027 | Take one bounded local snapshot before metadata/runtime migration | H | L | T | BACKLOG | Hidemyacc |
| ND3-028 | Quarantine unknown BrowserData directories with a reconcile preview | H | L | 0 | BACKLOG | Kameleo |
| ND3-029 | Retain a minimal Trash receipt without credentials | M | M | T | BACKLOG | DICloak + BitBrowser |
| ND3-030 | Preview cache, history and site-data cleanup separately | M | M | 0 | BACKLOG | AdsPower + Hidemyacc |
| ND3-031 | Export an allowlisted metadata-only backup with a manifest and checksum | M | M | T | BACKLOG | AdsPower |
| ND3-032 | Preview metadata import collisions before a transactional commit | M | M | 0 | BACKLOG | Multilogin + GoLogin |
| ND3-033 | Journal multi-file migrations as prepared, committed and complete | H | M | T | BACKLOG | Code audit |
| ND3-034 | Record the last successful runtime major per profile | H | M | T | BACKLOG | Kameleo + Camoufox |
| ND3-035 | Move profile document I/O away from the main actor | H | L | 0 | BACKLOG | Performance audit |
| ND3-036 | Keep launch recency in a compact crash-safe sidecar | M | M | T | BACKLOG | Performance audit |
| ND3-037 | Audit Keychain account identifiers against current profile IDs | M | M | T | BACKLOG | Security audit |
| ND3-038 | Gate new launches on real macOS memory pressure | H | M | 0 | BACKLOG | AdsPower reviews |
| ND3-039 | Show a bounded cancellable FIFO launch queue | M | M | 0 | BACKLOG | Multilogin + BitBrowser |
| ND3-040 | Slow passive process inventory when all states are stable | M | M | 0 | BACKLOG | Performance audit |
| ND3-041 | Highlight the profile owning the foreground managed browser window | M | M | 0 | BACKLOG | Multilogin |
| ND3-042 | Keep a bounded structured lifecycle ring without URLs or proxy data | M | M | T | BACKLOG | Kameleo + Hidemyacc |
| ND3-043 | Export an allowlisted local support bundle | M | S | T | BACKLOG | Incogniton |
| ND3-044 | Add privacy-safe signposts to startup and launch stages | M | S | 0 | BACKLOG | Performance audit |
| ND3-045 | Keep the last three sanitized proxy outcomes | M | S | T | BACKLOG | MoreLogin + BitBrowser |
| ND3-046 | Break proxy timing into lookup, connect, TLS and transfer phases | M | S | T | BACKLOG | Proxy diagnostics audit |
| ND3-047 | Add an explicit opt-in DNS/QUIC bypass audit | M | L | 0 | BACKLOG | Environment audit |
| ND3-048 | Store bounded local proxy provider and expiry labels | L | S | T | BACKLOG | MoreLogin |
| ND3-049 | Pin runtime bundle identifier, Team ID and designated requirement | H | M | 0 | BACKLOG | Security audit |
| ND3-050 | Hold stable runtime descriptors through the complete trust check | H | M | 0 | BACKLOG | Security audit |
| ND3-051 | Offer an explicit disposable runtime canary profile | M | M | 0 | BACKLOG | Camoufox + Undetectable |
| ND3-052 | Produce per-resource runtime size deltas in CI | M | S | 0 | BACKLOG | Camoufox |
| ND3-053 | Add a minimal packaged-app accessibility smoke harness | H | M | 0 | BACKLOG | Accessibility audit |
| ND3-054 | Restore row focus and scroll anchor after sheets and alerts | H | M | 0 | BACKLOG | Native macOS UX |
| ND3-055 | Offer a disposable scratch profile with explicit Save As Regular | M | M | 0 | BACKLOG | Ghost + Undetectable |
| ND3-056 | Save local templates containing only allowlisted metadata | M | M | T | BACKLOG | Octo + Multilogin |
| ND3-057 | Keep one visible default template with Reset | M | S | 0 | BACKLOG | AdsPower |
| ND3-058 | Support a bounded ordered startup-URL list | M | M | 0 | BACKLOG | NSTBrowser + Octo |
| ND3-059 | Separate Restore Last Tabs from startup URLs | M | M | 0 | BACKLOG | Ghost + Hidemyacc |
| ND3-060 | Show total, running and attention counts per folder | M | M | 0 | BACKLOG | GoLogin + Multilogin |
| ND3-061 | Inline-edit only name, tags, note and folder | M | M | 0 | BACKLOG | MoreLogin + AdsPower |
| ND3-062 | Drag profiles into folders with a menu equivalent | M | M | 0 | BACKLOG | Multilogin + Ghost |
| ND3-063 | Add a local pinned/recent quick switcher | M | M | 0 | BACKLOG | DICloak + BitBrowser |
| ND3-064 | Offer two tested row/table presets instead of a column builder | M | S | 0 | BACKLOG | Vision + GoLogin |
| ND3-065 | Save at most five local query/filter/sort views | M | M | T | BACKLOG | Octo + AdsPower |
| ND3-066 | Explain which profile field matched a structured search | M | S | 0 | BACKLOG | AdsPower |
| ND3-067 | Bring all managed browser windows forward | M | M | 0 | BACKLOG | Multilogin + AdsPower |
| ND3-068 | Recover managed browser windows outside visible displays | M | M | 0 | BACKLOG | BitBrowser + ixBrowser |
| ND3-069 | Hide endpoints, notes and paths during screen sharing | M | S | 0 | BACKLOG | Privacy UX audit |
| ND3-070 | Keep twenty bounded local metadata lifecycle events | M | M | T | BACKLOG | Hidemyacc |
| ND3-071 | Show largest profiles and owned-process resources on demand | M | M | 0 | BACKLOG | AdsPower + BitBrowser |
| ND3-072 | Offer search token suggestions without a query builder | L | M | 0 | BACKLOG | AdsPower |
| ND3-073 | Make safe table headers sortable with visible direction | M | M | 0 | BACKLOG | Vision + GoLogin |
| ND3-074 | Put three recent folders at the top of folder selection | L | S | 0 | BACKLOG | Operator UX audit |
| ND3-075 | Reorder folders with drag plus Move Up/Down commands | L | M | 0 | BACKLOG | Multilogin |
| ND3-076 | Let a tag chip apply its matching filter | M | S | 0 | BACKLOG | Octo |
| ND3-077 | Offer Rename immediately after Quick Create | M | S | 0 | BACKLOG | Undetectable |
| ND3-078 | Summarize bulk-created count and destination folder | M | S | 0 | BACKLOG | GoLogin |
| ND3-079 | Keep backend save failures visible above long editor forms | H | S | 0 | BACKLOG | Recovery UX audit |
| ND3-080 | Put Retry and Edit Address beside proxy failures | H | S | 0 | BACKLOG | MoreLogin + Incogniton |
| ND3-081 | Summarize Direct/proxy/auth/test state before Save | M | S | 0 | BACKLOG | Vision |
| ND3-082 | Show tag coverage during batch tag editing | L | M | 0 | BACKLOG | Octo |
| ND3-083 | Use responsive row fitting for Accessibility XL | H | M | 0 | BACKLOG | Accessibility audit |
| ND3-084 | Add opaque badge fallbacks for Increase Contrast | H | S | 0 | BACKLOG | Accessibility audit |
| ND3-085 | Explain shortcut availability context in Settings | L | S | 0 | BACKLOG | Native macOS UX |
| ND3-086 | Optionally restore only sidebar visibility and last selection | L | S | T | BACKLOG | Vision |
| ND3-087 | Add one quick-find popover for very large sidebars | L | M | 0 | BACKLOG | Vision + GoLogin |
| ND3-088 | Restore a trashed profile only through a collision-safe receipt | M | L | T | BACKLOG | DICloak + BitBrowser |
| ND3-089 | Add a read-only Recovery Center before any restore operation | M | M | T | BACKLOG | Hidemyacc |
| ND3-090 | Rotate three consistent metadata recovery generations | H | M | T | BACKLOG | Storage audit |
| ND3-091 | Cloud/team profile synchronization | L | L | heavy | DEFER | Privacy boundary |
| ND3-092 | Remote launch/stop API, MCP or CDP control plane | L | L | heavy | DEFER | RCE-class surface |
| ND3-093 | Cookie or password export/import | L | L | heavy | DEFER | Bearer-secret risk |
| ND3-094 | Integrated proxy marketplace and automatic purchasing | L | L | heavy | DEFER | Payment/tracking surface |
| ND3-095 | RPA, macro recorder or script marketplace | L | L | heavy | DEFER | Arbitrary-code surface |
| ND3-096 | In-app automatic runtime delta updater | M | L | heavy | DEFER | Supply-chain boundary |
| ND3-097 | Arbitrary CRX/ZIP extension installation from the manager | L | L | heavy | DEFER | Supply-chain/fingerprint drift |
| ND3-098 | Manual randomize-all fingerprint knobs | L | M | 0 | DEFER | Coherence risk |
| ND3-099 | Windows/Linux runtimes in the same release cycle | L | L | heavy | DEFER | Release-matrix expansion |
| ND3-100 | Download Chromium lazily after installation | M | L | smaller DMG | DEFER | Offline/notarization tradeoff |

## Selection rationale

The 25 selected items repair existing operator paths and storage boundaries.
They do not introduce a second browser core, cloud account, telemetry, remote
control or credential export. Their implementation must remain below existing
source-size budgets and pass the same packaged Chromium/live-fingerprint gates
as the exact baseline.
