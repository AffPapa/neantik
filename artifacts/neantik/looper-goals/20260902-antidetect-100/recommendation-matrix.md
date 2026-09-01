# NeAntik antidetect recommendation matrix

Research cut: 2026-09-02. Scope: local-first, minimal macOS profile manager. This matrix contains exactly 100 candidate product and UX patterns. Evidence codes resolve to current official product documentation below; public-review signals are supplementary and never treated as proof of technical effectiveness.

## Evidence index

- `V` — [Vision profile table](https://docs.browser.vision/profiles/overview)
- `O` — [Octo profile list and bulk actions](https://docs.octobrowser.net/en/profiles/profiles-page/)
- `G` — [GoLogin notes, tags and status](https://support.gologin.com/en/articles/14328143-notes-tags-and-status)
- `M` — [Multilogin profile and folder notes](https://multilogin.com/help/en_US/profile-organization-sorting/how-to-use-profile-and-folder-notes)
- `D` — [Dolphin Anty documentation](https://docs.dolphin-anty.com/)
- `A` — [AdsPower help center](https://help.adspower.com/)
- `I` — [Incogniton knowledge hub](https://docs.incogniton.com/)
- `K` — [Kameleo profile lifecycle](https://developer.kameleo.io/concepts/profiles/)
- `R` — [MoreLogin group management](https://support.morelogin.com/en/articles/10244822-profile-group-management)
- `H` — [HideMyAcc profile management](https://docs.hidemyacc.com/hidemyacc-2.0-instructions/manage-your-profiles)
- `U` — [Undetectable profile management](https://docs.undetectable.io/working-with-profiles/)
- `DC` — [DICloak profile list](https://help.dicloak.com/browser-profiles/)
- `B` — [BitBrowser profile functions](https://doc.bitbrowser.net/help1/browser-profiles/features-and-functions)
- `VM` — [VMLogin interface guide](https://www.vmlogin.us/instruction.pdf)
- `N` — [Nstbrowser group management](https://docs.nstbrowser.io/guide/advanced/group.html)
- `IX` — [ixBrowser support index](https://www.ixbrowser.com/guide)
- `L` — [Lalicat bulk creation](https://www.lalicat.com/create-multiple-profiles-in-bulk)
- `C` — [ClonBrowser help center](https://www.clonbrowser.com/help/)
- `GL` — [GenLogin profile overview](https://docs.genlogin.com/group-profiles/create-profile/overview)
- `W` — [WADE profile model](https://docs.wade.is/api/profiles/profile_schema/)
- `MU` — [MuLogin documentation](https://www.mulogin.com/doc/en/?cat=13)
- `S` — [SessionBox features](https://sessionbox.io/features)
- `GH` — [Ghost Browser identities](https://support.ghostbrowser.com/article/387-the-default-identity)
- `MF` — [Maskfog getting started](https://help.maskfog.com/?lang=en&p=370)
- `HS` — [Hubstudio product overview](https://www.hubstudio.io/)
- `1B` — [1Browser release notes](https://1browser.com/release-notes/)
- `FI` — [FlashID tags](https://docs.flashid.app/api-reference/tags)
- `AB` — [AntBrowser feature overview](https://www.antbrowser.com/es/)

## Internal evidence index

These codes bind the selected set to the implementation currently present in the worktree. They are implementation evidence, not proof that the complete source, release, signing, notarization or live-publication gates have passed.

- `IN-01` — `Sources/NeAntik/ProfileNoteEditorView.swift`; `Tests/NeAntikTests/UXDraftProtectionTests.swift`; `scripts/tests/test_responsive_ui_contract.py`
- `IN-02` — `Sources/NeAntik/BulkProxyImport.swift`; `Tests/NeAntikTests/UXDraftProtectionTests.swift`; `scripts/tests/test_responsive_ui_contract.py`
- `IN-03` — `Sources/NeAntik/ProfileEditorView.swift`; `Tests/NeAntikTests/ProfileEditorPresentationTests.swift`; `scripts/tests/test_responsive_ui_contract.py`
- `IN-04` — `Sources/NeAntik/ContentView.swift`; `scripts/tests/test_responsive_ui_contract.py`
- `IN-05` — `Sources/NeAntik/ProfileBatchActions.swift`; `Tests/NeAntikTests/ResponsiveLayoutRenderTests.swift`; `scripts/tests/test_responsive_ui_contract.py`
- `IN-06` — `Sources/NeAntik/ProfileCommands.swift`; `Sources/NeAntik/ContentView.swift`; `Tests/NeAntikTests/ProfileCommandPresentationTests.swift`
- `IN-07` — `Sources/NeAntik/NeAntikShortcutCatalog.swift`; `Sources/NeAntik/NeAntikSettingsView.swift`; `Tests/NeAntikTests/NeAntikShortcutCatalogTests.swift`
- `IN-08` — `Sources/NeAntik/ContentViewState.swift`; `Sources/NeAntik/ContentView.swift`; `Tests/NeAntikTests/WorkspaceAlertPresentationTests.swift`
- `IN-09` — `Sources/NeAntik/ProfileEditorView.swift`; `Tests/NeAntikTests/ResponsiveLayoutRenderTests.swift`; `scripts/tests/test_responsive_ui_contract.py`
- `IN-10` — `Sources/NeAntik/BrowserRuntimePreflight.swift`; `Tests/NeAntikTests/BrowserRuntimePreflightTests.swift`
- `IN-11` — `Sources/NeAntik/FingerprintAudit.swift`; `Sources/NeAntik/BrowserProcessManager.swift`; `Tests/NeAntikTests/FingerprintAuditTests.swift`
- `IN-12` — `Sources/NeAntik/DevToolsSecurity.swift`; `Sources/NeAntik/FingerprintAudit.swift`; `Tests/NeAntikTests/FingerprintAuditTests.swift`
- `IN-13` — `Sources/NeAntik/ProxyTester.swift`; `Tests/NeAntikTests/ProxyTesterTests.swift`
- `IN-14` — `Sources/NeAntik/BrowserRuntimeInspector.swift`; `Tests/NeAntikTests/BrowserRuntimeInspectorTests.swift`
- `IN-15` — `Release-NeAntik.command`; `scripts/Run-NeAntik-Release.command`; Direct release shell scripts; `scripts/tests/test_release_direct_script.py`
- `IN-16` — `scripts/run-isolated-release-python.py`; `scripts/tests/test_run_isolated_release_python.py`

Frequency: `H` daily, `M` weekly, `L` occasional. Complexity: `XS/S/M/L`. Bundle impact: `0` negligible, `T` under 1 MB, `S` 1–10 MB, `M` 10–50 MB, `L` over 50 MB. Decision: `SELECT` is in the atomic top 25, `NEXT` is a validated backlog candidate, and `REJECT` conflicts with the local/minimal product boundary.

| ID | Category | Evidence/source | Effect | Frequency | Complexity | Risk / weight | Decision |
|---|---|---|---|---|---|---|---|
| AD-001 | Note draft safety | IN-01 | Cancel asks before discarding a dirty note | H | S | Low / 0 | SELECT |
| AD-002 | Note keyboard safety | IN-01 | Escape follows the same dirty-note confirmation path | H | S | Low / 0 | SELECT |
| AD-003 | Note sheet safety | IN-01 | Interactive sheet dismissal is disabled while the note is dirty | H | S | Low / 0 | SELECT |
| AD-004 | Proxy-import draft safety | IN-02 | Cancel asks before discarding dirty proxy-import input or options | M | S | Medium / 0 | SELECT |
| AD-005 | Proxy-import keyboard safety | IN-02 | Escape follows the guarded proxy-import dismissal path | M | S | Medium / 0 | SELECT |
| AD-006 | Proxy-import sheet safety | IN-02 | Interactive dismissal is blocked while dirty and while creation runs | M | S | Medium / 0 | SELECT |
| AD-007 | Editor orientation | IN-03 | Heading explicitly distinguishes profile creation from editing | H | S | Low / 0 | SELECT |
| AD-008 | Progressive disclosure | IN-03 | Advanced summary explicitly includes the startup URL | H | XS | Low / 0 | SELECT |
| AD-009 | Search discoverability | IN-04 | Visible help documents field syntax and quoted values | H | S | Low / 0 | SELECT |
| AD-010 | Responsive bulk UX | IN-05 | Compact batch bar keeps actions reachable without horizontal hiding | H | M | Low / 0 | SELECT |
| AD-011 | Command consistency | IN-06 | Note command uses one availability rule during transient states | H | S | Low / 0 | SELECT |
| AD-012 | Accessibility | IN-07 | Shortcut labels use spoken modifier and key names | M | S | Low / 0 | SELECT |
| AD-013 | Readiness recovery | IN-08 | Process and storage alerts offer a direct readiness recovery action | M | S | Low / 0 | SELECT |
| AD-014 | Secret-entry UX | IN-09 | Proxy password has an explicit temporary reveal/hide control | M | S | High / 0 | SELECT |
| AD-015 | Runtime trust | IN-10 | Unknown signature on fingerprint runtime fails closed | H | S | High / 0 | SELECT |
| AD-016 | Shipping launch safety | IN-11 | Legacy single-process and no-sandbox diagnostic arguments cannot ship | L | M | High / 0 | SELECT |
| AD-017 | DevTools file safety | IN-12 | DevToolsActivePort read is bounded and uses O_NOFOLLOW | M | M | High / 0 | SELECT |
| AD-018 | DevTools race safety | IN-12 | DevTools port file must be regular, owner-held, single-link and inode-stable | M | L | High / 0 | SELECT |
| AD-019 | DevTools endpoint safety | IN-12 | WebSocket endpoint requires ws, 127.0.0.1 and the expected port | M | M | High / 0 | SELECT |
| AD-020 | DevTools URL safety | IN-12 | WebSocket path is strict and credentials, query and fragment are rejected | M | M | High / 0 | SELECT |
| AD-021 | Child-process isolation | IN-13 | Curl proxy test receives a small sanitized environment | H | S | High / 0 | SELECT |
| AD-022 | Runtime binding | IN-14 | Inspector accepts exactly one non-symlink versioned framework binary | H | M | High / 0 | SELECT |
| AD-023 | Release shell safety | IN-15 | Entrypoints set private umask/fixed PATH and DMG uses absolute Apple tools | L | M | High / 0 | SELECT |
| AD-024 | Release Python isolation | IN-16 | Runner uses system Git and prevents repository stdlib shadowing | L | M | High / 0 | SELECT |
| AD-025 | Release Python mode | IN-16 | Runner requires Python isolated and no-bytecode flags -I -B | L | S | High / 0 | SELECT |
| AD-026 | Metadata | V,O,VM,W | Display last launch, last edit and accumulated runtime | H | S | Low / 0 | NEXT |
| AD-027 | Storage | O,K | Display per-profile size and total profile-data budget | M | M | Low / 0 | NEXT |
| AD-028 | Destructive safety | V,O,B,DC | Move deletions to a restorable local trash | M | M | Medium / 0 | NEXT |
| AD-029 | Duplication | H,B,K | Let duplicate keep or regenerate fingerprint and proxy independently | M | M | High / 0 | NEXT |
| AD-030 | Templates | O,U,IX,V | Save small local templates and default settings | H | M | Medium / 0 | NEXT |
| AD-031 | Onboarding | I,1B,C | Teach create, proxy check and launch in three steps | L | S | Low / 0 | NEXT |
| AD-032 | Creation | G,O,V | Inherit the currently selected folder on creation | H | XS | Low / 0 | NEXT |
| AD-033 | Navigation | B,DC,IX | Pin frequently used profiles above ordinary sorting | H | S | Low / 0 | NEXT |
| AD-034 | Table UX | O,B,VM | Sort every visible column in both directions | H | S | Low / 0 | NEXT |
| AD-035 | Table UX | O,N,MU | Choose visible columns without changing stored data | M | M | Low / 0 | NEXT |
| AD-036 | Table UX | O | Resize and reorder columns persistently | M | M | Low / 0 | NEXT |
| AD-037 | Table UX | O,B | Reset column layout to a tested default | L | XS | Low / 0 | NEXT |
| AD-038 | Density | O,V | Offer compact and comfortable row density | H | S | Low / 0 | NEXT |
| AD-039 | Accessibility | O + macOS HIG | Support VoiceOver, logical focus, contrast and large text | H | M | Low / 0 | NEXT |
| AD-040 | Keyboard | O | Focus profile search with Command-F | H | XS | Low / 0 | NEXT |
| AD-041 | Filters | O,DC | Filter profiles with no assigned proxy | M | XS | Low / 0 | NEXT |
| AD-042 | Filters | K,R,B | Filter Running, Failed and Degraded lifecycle states | H | S | Low / 0 | NEXT |
| AD-043 | Runtime safety | U,IX,1B | Warn when the bundled browser core is stale | M | M | Medium / 0 | NEXT |
| AD-044 | Diagnostics | I,W,1B | Put a Diagnose action next to a failed profile | M | S | Medium / 0 | NEXT |
| AD-045 | Accessibility | G,O,FI | Encode status with text and symbol, not color alone | H | XS | Low / 0 | NEXT |
| AD-046 | Tags | O,G,R | Create a tag inside the assignment picker | M | S | Low / 0 | NEXT |
| AD-047 | Folders | M,N | Attach a short non-secret note to a folder | M | S | Medium / 0 | NEXT |
| AD-048 | Folders | V,N | Show total, running and failed counts in the sidebar | H | S | Low / 0 | NEXT |
| AD-049 | Bulk creation | O,L | Auto-number names created in one batch | M | S | Low / 0 | NEXT |
| AD-050 | Support | O,DC,W | Copy a profile identifier without copying account data | L | XS | Low / 0 | NEXT |
| AD-051 | Local data | K,W | Reveal the selected profile directory in Finder | M | XS | Medium / 0 | NEXT |
| AD-052 | Diagnostics | I,W | View a bounded local launch log inside the app | M | M | High / 0 | NEXT |
| AD-053 | Diagnostics | I,W,1B | Generate a redacted support bundle with an allowlist | L | L | High / T | NEXT |
| AD-054 | Auditability | O,U | Keep a bounded local history of metadata operations | M | M | Medium / 0 | NEXT |
| AD-055 | Recovery | O,B | Undo the latest folder, tag or status change | M | M | Low / 0 | NEXT |
| AD-056 | Destructive safety | O,B,DC | Confirm destructive bulk work with names and count | M | S | Low / 0 | NEXT |
| AD-057 | Bulk UX | O,B,N | Cancel bulk items that have not begun | M | M | Medium / 0 | NEXT |
| AD-058 | Bulk UX | O,B,L | Report bulk progress and per-item failures | M | M | Medium / 0 | NEXT |
| AD-059 | Performance | O,B,L | Limit simultaneous launches by resource budget | M | M | Medium / 0 | NEXT |
| AD-060 | Lifecycle | O,V,B | Stop all running profiles through normal session persistence | H | M | Medium / 0 | NEXT |
| AD-061 | Lifecycle | K,1B | Focus an existing window instead of starting a duplicate | H | S | Low / 0 | NEXT |
| AD-062 | Navigation | 1B,GH | Relaunch or focus the most recently used profile | H | S | Low / 0 | NEXT |
| AD-063 | Startup | N,B,GL | Open a small ordered list of startup URLs | H | S | Low / 0 | NEXT |
| AD-064 | Bookmarks | N,G,W | Reuse local bookmark sets without cloud sync | M | M | Low / 0 | NEXT |
| AD-065 | Extensions | N,G,GL | Reuse local extension sets | M | M | High / 0 | NEXT |
| AD-066 | Extensions | G,U,GH | Enable or disable an installed extension per profile | M | M | High / 0 | NEXT |
| AD-067 | Extension safety | GH,N | Warn about broad permissions and non-store sources | M | M | High / T | NEXT |
| AD-068 | Maintenance | U,B,DC | Clear cache while preserving cookies and sessions | M | M | Medium / 0 | NEXT |
| AD-069 | Data controls | U,B,DC | Offer scoped wipe for cache, history, cookies and storage | M | M | High / 0 | NEXT |
| AD-070 | Cookies | O,U,I | Preview and validate cookie imports before mutation | M | M | High / 0 | NEXT |
| AD-071 | Cookies | G,U,I | Warn and reveal destination for cookie export | L | S | High / 0 | NEXT |
| AD-072 | Proxy input | O,A,I,MF | Parse common proxy text formats locally | H | M | High / 0 | NEXT |
| AD-073 | Proxy input | O,R,GH,MU | Preview and validate a bulk proxy import | M | M | High / 0 | NEXT |
| AD-074 | Proxy safety | A,R,I | Warn when several profiles accidentally share one proxy | M | S | Medium / 0 | NEXT |
| AD-075 | Proxy assignment | A | Optionally assign only currently unused proxies | M | M | Medium / 0 | NEXT |
| AD-076 | Proxy rotation | O,B,W | Run an explicit rotation URL with cooldown and result | M | M | High / 0 | NEXT |
| AD-077 | Secret handling | O,R,W | Redact proxy passwords in every screen and log | H | S | High / 0 | NEXT |
| AD-078 | Leak diagnostics | G,U,N | Detect local-IP or WebRTC exposure before work | M | L | High / T | NEXT |
| AD-079 | Leak diagnostics | N,U | Report DNS and proxy-path consistency separately | M | L | High / T | NEXT |
| AD-080 | Safe defaults | G,GL,V | Align timezone, language and geolocation with exit IP | H | L | High / 0 | NEXT |
| AD-081 | Fingerprint UX | G,K,M | Summarize effective fingerprint beside the form | M | M | Medium / 0 | NEXT |
| AD-082 | Identity safety | G,I,B | Confirm fingerprint regeneration and explain persistence impact | L | S | High / 0 | NEXT |
| AD-083 | Identity safety | G,K | Lock incompatible OS and browser-core fields after creation | M | M | High / 0 | NEXT |
| AD-084 | Progressive disclosure | M,G,U | Keep risky tuning behind an Advanced mode | H | M | Low / 0 | NEXT |
| AD-085 | Validation | G,U,K | Show inline errors and a diff before risky save | M | L | Medium / 0 | NEXT |
| AD-086 | Cloud | G,I,K,S | Mandatory cloud synchronization adds privacy and conflict risk | L | L | High / S | REJECT |
| AD-087 | Teams | A,I,N,MF,HS | Team RBAC is outside the local single-user product | L | L | High / S | REJECT |
| AD-088 | Sharing | O,G,H,DC | Profile transfer expands cookie and ownership risk | L | L | High / S | REJECT |
| AD-089 | Remote runtime | R,M,HS | Cloud phones and remote browsers require heavy infrastructure | L | L | High / L | REJECT |
| AD-090 | Automation | D,A,C | Visual RPA expands UI, tests and abuse surface | L | L | High / M | REJECT |
| AD-091 | Remote API | V,I,U,W,MU | A network API creates token and authorization surface | L | L | High / S | REJECT |
| AD-092 | Marketplace | A,N,GL | An extension marketplace creates supply-chain obligations | L | L | High / M | REJECT |
| AD-093 | Commerce | O,A,I,1B | A proxy shop adds payments, support and vendor lock-in | L | L | High / S | REJECT |
| AD-094 | AI | I | An in-app AI assistant adds telemetry without core value | L | L | High / M | REJECT |
| AD-095 | Credentials | N,V,B | Password and 2FA storage should remain with a dedicated vault | M | L | High / S | REJECT |
| AD-096 | Automation | O,G,I,U,AB | Cookie warming robots are not profile-management essentials | L | L | High / M | REJECT |
| AD-097 | Input simulation | O,I,U,B,MU | Human-typing simulation adds non-core behavioral automation | L | M | Medium / T | REJECT |
| AD-098 | Emulation | M,MF,AB | Full mobile emulation requires a separate heavy runtime | L | L | High / L | REJECT |
| AD-099 | Identity model | S,GH | Per-tab identities make isolation less legible than per-window profiles | L | L | High / M | REJECT |
| AD-100 | Trust claims | N,1B | A magic antidetect score creates false security confidence | M | L | High / T | REJECT |

## Selection rule

The selected set is the 25 changes actually implemented in the current worktree: 14 bounded UX/accessibility corrections and 11 runtime/release hardening corrections. Cloud, teams, RPA, marketplaces, credential storage, commerce and heavy alternate runtimes remain excluded. `SELECT` means implemented locally, not fully gated or released.
