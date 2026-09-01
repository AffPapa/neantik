# NeAntik recommendation matrix v2

Research cut: 2026-09-02. `SELECT` marks the 25 items implemented in this
cycle with matching source and test evidence. Weight describes bundled
payload: `0` means no new dependency, asset or runtime resource; `T` means a
small stored payload below 1 MiB. It is not a claim of zero compiled-code
bytes.

## Source index

- Official products: [Vision](https://docs.browser.vision/profiles/overview),
  [Dolphin Anty](https://docs.dolphin-anty.com/en/getting-started/quick-start-in-dolphin-anty),
  [GoLogin](https://support.gologin.com/en/articles/14328143-notes-tags-and-status),
  [Multilogin](https://multilogin.com/help/how-to-use-profile-and-folder-notes),
  [AdsPower](https://help.adspower.com/docs/creating_browser_profiles),
  [Octo](https://docs.octobrowser.net/en/profiles/start/),
  [Incogniton](https://docs.incogniton.com/),
  [MoreLogin](https://support.morelogin.com/en/articles/10204297-profile-settings),
  [Kameleo](https://developer.kameleo.io/concepts/profiles/),
  [Hidemyacc](https://docs.hidemyacc.com/hidemyacc-3.0-features/create-new-profile/new-profile/proxy-tab),
  [Undetectable](https://docs.undetectable.io/working-with-profiles/create-and-run/),
  [Linken Sphere](https://ls.app/docs/sessions/creating-and-launching-session),
  [GenLogin](https://docs.genlogin.com/group-profiles/create-profile/overview),
  [NSTBrowser](https://docs.nstbrowser.io/guide/fingerprint-browser/create.html),
  [DICloak](https://help.dicloak.com/new-subscriber-getting-started-manual/),
  [BitBrowser](https://doc.bitbrowser.net/help1/browser-profiles/features-and-functions),
  [VMLogin](https://www.vmlogin.us/help/fingerprint/vmlogin-details.html),
  [ixBrowser](https://ixbrowser.com/update-logs),
  [Lalicat](https://www.lalicat.com/create-multiple-profiles-in-bulk),
  [ClonBrowser](https://www.clonbrowser.com/help/),
  [WADE](https://docs.wade.is/api/profiles/profile_schema/),
  [MuLogin](https://www.mulogin.com/doc/en/?cat=13),
  [SessionBox](https://sessionbox.io/features),
  [Ghost Browser](https://support.ghostbrowser.com/article/320-identities),
  [Maskfog](https://help.maskfog.com/?lang=en&p=364),
  [Hubstudio](https://www.hubstudio.io/),
  [1Browser](https://1browser.com/release-notes/),
  [FlashID](https://docs.flashid.app/api-reference/tags), and
  [AntBrowser](https://www.antbrowser.com/es/).
- Directional review signals only: [GoLogin](https://www.g2.com/products/gologin-gologin/reviews),
  [AdsPower](https://www.g2.com/products/adspower-browser/reviews),
  [Multilogin](https://www.g2.com/products/multilogin/reviews?qs=pros-and-cons),
  [Dolphin](https://www.trustpilot.com/review/dolphin-anty.com), and
  [Octo](https://www.trustpilot.com/review/octobrowser.net).

| ID | Recommendation | Value | Effort | Weight | Decision |
|---|---|---:|---:|---:|---|
| ND2-001 | Auto-hide a revealed proxy password after a short lease | H | S | 0 | SELECT |
| ND2-002 | Hide revealed secrets when NeAntik resigns active | H | XS | 0 | SELECT |
| ND2-003 | Rotate reveal leases on credential edits and invalidate them on dismissal | H | S | 0 | SELECT |
| ND2-004 | Clear only NeAntik-owned secret clipboard leases on backgrounding | H | S | 0 | SELECT |
| ND2-005 | Start the proxy-test child before writing bounded stdin | H | M | 0 | SELECT |
| ND2-006 | Make proxy-secret stdin writing cancellation-aware | H | M | 0 | SELECT |
| ND2-007 | Close proxy stdin deterministically on success, exit and cancellation | H | S | 0 | SELECT |
| ND2-008 | Retain the active profile-storage measurement task | M | S | 0 | SELECT |
| ND2-009 | Cancel a stale storage scan when profile selection changes | H | S | 0 | SELECT |
| ND2-010 | Cancel storage measurement when the inspector disappears | M | XS | 0 | SELECT |
| ND2-011 | Create the one-second running-session timer only when needed | M | S | 0 | SELECT |
| ND2-012 | Replace implicit duplication with an explicit native sheet | H | M | 0 | SELECT |
| ND2-013 | Validate and preview the duplicate profile name | M | S | 0 | SELECT |
| ND2-014 | Let duplicate choose Direct or copy the source proxy | H | S | 0 | SELECT |
| ND2-015 | Copy a proxy password only after separate explicit consent | H | S | 0 | SELECT |
| ND2-016 | Make destination-folder preservation visible in duplicate flow | M | XS | 0 | SELECT |
| ND2-017 | State and enforce fresh UUID, BrowserData and fingerprint identity | H | S | 0 | SELECT |
| ND2-018 | Show created, modified and last-launched metadata together | H | S | 0 | SELECT |
| ND2-019 | Add deterministic recently-modified ordering | H | S | 0 | SELECT |
| ND2-020 | Detect reused proxy endpoints without passwords or network calls | H | S | 0 | SELECT |
| ND2-021 | Show a non-blocking shared-proxy warning in editor and inspector | H | M | 0 | SELECT |
| ND2-022 | Add an ordinary-only Stop All action for confirmed sessions | H | M | 0 | SELECT |
| ND2-023 | Confirm Stop All with exact eligible and excluded counts | H | S | 0 | SELECT |
| ND2-024 | Re-inspect the embedded runtime immediately before launch | H | M | 0 | SELECT |
| ND2-025 | Fail closed if fresh runtime identity/trust differs from resolution | H | M | 0 | SELECT |
| ND2-026 | Add a local environment seal and human-readable drift diff | H | M | 0 | BACKLOG |
| ND2-027 | Preview browser-core migrations before first affected launch | H | M | 0 | BACKLOG |
| ND2-028 | Create a disposable canary profile for runtime validation | M | M | T | BACKLOG |
| ND2-029 | Add an offline installed-app Trust Center | H | M | 0 | BACKLOG |
| ND2-030 | Distinguish BrowserData lock, permission and corruption preflight | H | M | 0 | BACKLOG |
| ND2-031 | Offer explicit crash recovery choices instead of a generic error | H | M | 0 | BACKLOG |
| ND2-032 | Take a bounded local snapshot before metadata/runtime migration | M | L | T | BACKLOG |
| ND2-033 | Export/import only encrypted allowlisted configuration | M | L | T | BACKLOG |
| ND2-034 | Highlight the profile owning the active browser window | H | M | 0 | BACKLOG |
| ND2-035 | Return the manager after the last managed browser closes | M | S | 0 | BACKLOG |
| ND2-036 | Put Fix Proxy directly beside route failures | H | S | 0 | BACKLOG |
| ND2-037 | Explain every disabled Start with one reason and recovery action | H | S | 0 | BACKLOG |
| ND2-038 | Tile managed browser windows with native macOS APIs | M | M | 0 | BACKLOG |
| ND2-039 | Bring all managed browser windows forward | M | M | 0 | BACKLOG |
| ND2-040 | Recover managed windows that are outside visible displays | M | S | 0 | BACKLOG |
| ND2-041 | Save up to five local named query/sort views | M | M | 0 | BACKLOG |
| ND2-042 | Keep a revision-safe in-memory undo stack of five operations | M | M | 0 | BACKLOG |
| ND2-043 | Add an explicitly temporary scratch profile | M | M | 0 | BACKLOG |
| ND2-044 | Edit folder and tags from a small native popover | H | S | 0 | BACKLOG |
| ND2-045 | Allow safe folder-scoped defaults without fingerprint settings | M | M | 0 | BACKLOG |
| ND2-046 | Show launch stages only while delayed or failing | H | M | 0 | BACKLOG |
| ND2-047 | Explain which field matched a structured search | M | S | 0 | BACKLOG |
| ND2-048 | Store optional proxy expiry/provider labels without commerce | M | S | 0 | BACKLOG |
| ND2-049 | Show the last three sanitized proxy outcomes | M | M | T | BACKLOG |
| ND2-050 | Enforce an allowlisted stopped-profile cache budget | M | L | 0 | BACKLOG |
| ND2-051 | Block heavy new work on critically low disk space | H | M | 0 | BACKLOG |
| ND2-052 | Add visible Trash retention and purge preview | M | M | 0 | BACKLOG |
| ND2-053 | Quarantine and explain orphan BrowserData directories | M | L | 0 | BACKLOG |
| ND2-054 | Record on-demand profile size deltas | M | S | T | BACKLOG |
| ND2-055 | Relocate profile storage with copy, verify and rollback | M | L | 0 | BACKLOG |
| ND2-056 | Gate new launches on real macOS memory pressure | H | M | 0 | BACKLOG |
| ND2-057 | Measure resources only for owned process trees | M | M | 0 | BACKLOG |
| ND2-058 | Keep five sanitized launch-phase timings | M | M | T | BACKLOG |
| ND2-059 | Audit and prune runtime resources through an allowlisted manifest | H | L | smaller | BACKLOG |
| ND2-060 | Bind an optional shared immutable runtime by exact hash | M | L | smaller | BACKLOG |
| ND2-061 | Add signed delta runtime updates only with atomic rollback | M | L | T | BACKLOG |
| ND2-062 | Compact only proven disposable cache classes after close | M | L | 0 | BACKLOG |
| ND2-063 | Add an explicit per-profile low-data mode | L | M | 0 | BACKLOG |
| ND2-064 | Support arrow/Space/Return navigation in the profile list | H | M | 0 | BACKLOG |
| ND2-065 | Add compact quick editing for safe metadata | H | M | 0 | BACKLOG |
| ND2-066 | Put one contextual recovery action in an attention row | H | S | 0 | BACKLOG |
| ND2-067 | Keep twenty bounded local metadata lifecycle events | M | M | T | BACKLOG |
| ND2-068 | Offer two tested table presets instead of a column builder | M | S | 0 | BACKLOG |
| ND2-069 | Summarize creation and risky-field changes before saving | H | S | 0 | BACKLOG |
| ND2-070 | Remap only safe in-app shortcuts with conflict validation | M | M | 0 | BACKLOG |
| ND2-071 | Open pinned/recent profiles through a small quick switcher | M | M | 0 | BACKLOG |
| ND2-072 | Drag a profile to a folder with an accessible menu alternative | M | M | 0 | BACKLOG |
| ND2-073 | Rename profile/folder inline with native edit semantics | M | S | 0 | BACKLOG |
| ND2-074 | Support Shift-range batch selection | M | M | 0 | BACKLOG |
| ND2-075 | Restore row focus and scroll anchor after modal work | H | S | 0 | BACKLOG |
| ND2-076 | Save local templates without cookies, IDs or secrets | M | M | 0 | BACKLOG |
| ND2-077 | Choose one visible default template with Reset | M | S | 0 | BACKLOG |
| ND2-078 | Add a bounded, non-secret folder note | L | S | 0 | BACKLOG |
| ND2-079 | Separate user workflow status from runtime state | L | M | 0 | BACKLOG |
| ND2-080 | Support a bounded ordered startup-URL list | M | M | 0 | BACKLOG |
| ND2-081 | Measure workspace storage and largest profiles on demand | M | M | 0 | BACKLOG |
| ND2-082 | Offer scoped cache/history/site-data cleanup | M | M | 0 | BACKLOG |
| ND2-083 | Let users lower, but never exceed, the safe launch limit | M | M | 0 | BACKLOG |
| ND2-084 | Show and cancel profiles waiting in a launch queue | M | M | 0 | BACKLOG |
| ND2-085 | Show a banner only during real macOS memory pressure | M | M | 0 | BACKLOG |
| ND2-086 | Temporarily hide sensitive fields during screen sharing | M | S | 0 | BACKLOG |
| ND2-087 | Copy an allowlisted safe profile summary | M | S | 0 | BACKLOG |
| ND2-088 | Show detailed last proxy check without exact persisted exit IP | M | S | 0 | BACKLOG |
| ND2-089 | Store reusable local proxies only after a separate threat model | L | L | 0 | DEFER |
| ND2-090 | Filter saved proxies by unused/shared/failed/stale | L | S | 0 | DEFER |
| ND2-091 | Mark edits that apply on the next browser launch | M | S | 0 | BACKLOG |
| ND2-092 | Give every disabled control a visible or accessible reason | H | S | 0 | BACKLOG |
| ND2-093 | Add concise VoiceOver custom actions to profile rows | H | M | 0 | BACKLOG |
| ND2-094 | Focus the first invalid field and announce validation count once | H | M | 0 | BACKLOG |
| ND2-095 | Ask how to quit when managed browsers are still running | H | M | 0 | BACKLOG |
| ND2-096 | Validate password bounds at the Keychain read/write boundary | H | M | 0 | BACKLOG |
| ND2-097 | Read runtime plist/binaries through bounded stable descriptors | H | M | 0 | BACKLOG |
| ND2-098 | Show total/running/attention counts for each folder | M | M | 0 | BACKLOG |
| ND2-099 | Display the age of the embedded security baseline | H | M | T | BACKLOG |
| ND2-100 | Offer a short Undo window before committing deletion | H | M | 0 | BACKLOG |

## Implemented slices and evidence

| IDs | Result | Primary evidence |
|---|---|---|
| ND2-001..004 | Leased password reveal and owned-clipboard cleanup | `SensitiveRevealLeaseTests`, `ProfileEditorPasswordTests`, responsive UI contract |
| ND2-005..007 | Non-blocking cancellable proxy stdin transport | `ProxyTesterTests` large-input, early-exit, cancellation and secret-isolation cases |
| ND2-008..010 | Cancellable on-demand storage measurement | `ProfileStorageMeasurementTests` plus selection/disappearance task ownership |
| ND2-011 | No idle one-second timeline | `BrowserProcessLifecyclePresentationTests` and `RunningProfilesTimelineStrip` |
| ND2-012..017 | Explicit safe duplicate sheet | `ProfileDuplicationTests` and light/dark responsive renders |
| ND2-018..021 | Recency metadata/order and credential-free proxy reuse warning | `ProfileListOrderingTests`, `ProxyReuseAssessmentTests`, editor/detail renders |
| ND2-022..023 | Confirmed ordinary-only group stop | `BrowserProcessLifecyclePresentationTests`; the manager revalidates every requested ID |
| ND2-024..025 | Fresh fail-closed runtime trust immediately before launch | `BrowserRuntimeLaunchTrustTests` |

The selection adds no cloud account, telemetry, automation marketplace,
extension store, fingerprint randomization control or bundled dependency. It
therefore keeps the installed-runtime weight unchanged; source-only additions
are below one MiB.
