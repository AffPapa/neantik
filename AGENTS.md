# NeAntik agent instructions

- When repository documentation conflicts with conventions established by the existing code, follow the code conventions for implementation and list every documentation/code mismatch found in the final response.
- Resource admission uses exported sysctl flags, not the internal XNU enum;
  follow `docs/NEANTIK_RESOURCE_ADMISSION.md` before changing pressure gates.

- First-release execution: ship the qualified Chromium-only variant. Defer
  WebKit until its production runtime and source gates pass. Record unsupported
  timezone, locale and WebRTC per exact runtime evidence; never imply absolute anonymity.
- Freeze one candidate per product change. Do not create a replacement for
  receipt, documentation or source-offer edits alone; finish its scoped runtime
  check, diagnose failures, and batch source/license and release closure once.
- Reuse matching prior evidence; do not turn inventory, audit or checkpoint
  updates into new gates. Record only the next decision-changing action.
- Direct Distribution only: GitHub `AffPapa/neantik` and browser.free via the
  existing Sites project. Preserve Developer ID, notarization, stapling,
  Gatekeeper, immutable assets and rollback. Never use App Store Connect.
- Canonical signer SHA-1 `474F7C78F33EE324C24F6F5AE0443EB713E85E60` is already
  in `~/Library/Keychains/login.keychain-db`; sandbox-scoped zero results can
  be false negatives. Follow `docs/NEANTIK_SIGNING_IDENTITY.md`; never issue
  another cert or export the private key into files/repo.
- AffPapa is excluded by the user. Only after new explicit authorization read
  `ops/affpapa/README.md` and use its restricted client. Never use raw SSH,
  SCP/SFTP/rsync or direct server edits; missing AffPapa keys do not block us.
- Swift iteration: `./Develop-NeAntik.command` with disposable fixtures;
  targeted tests: `python3 -B scripts/test-manager-fast.py --suite NameTests`
  (repeat suites). Use the project's developer-dir resolver, local caches,
  jobs2 and serial tests. Do not change inputs of a running build.
- Python contracts: set `PYTHONDONTWRITEBYTECODE=1` as well as `python3 -B`;
  `-B` alone does not protect subprocess imports. Preserve and quarantine only
  diagnosed own-generated source bytecode; never clean shared build caches.
- Substantive manager/workflow changes use
  `.agents/skills/neantik-development/SKILL.md`; the read-only check planner
  explains selection. Unknown/shared inputs require full regression. Small
  prose fixes need relevant diff/claim/link review. Planning is never PASS.
- Read one CURRENT linked by the operator workspace's project context index;
  public source checkouts need not contain private checkpoints.
  CURRENT is the sole rolling status; index/roadmap link to it rather than
  copying candidate hashes or next actions. Old snapshots remain archival.
  Historical receipts answer specific questions. App/runtime/Site/hosted
  evidence are separate; repeat a gate only for changed inputs or a failure.
- Before any Apple notarization or other external submission, preflight the exact frozen bytes against the exact consumer/harness requirements (bundle identity, fixture root, nested runtime, signatures, and launcher bindings); for owned-WebKit Dev ZIPs, run `python3 -B scripts/verify_owned_webkit_qa_archive.py --candidate <candidate.json> --run-plan <plan.json>` before requesting approval or submitting. Do not spend an approval or external submission on a package that cannot pass the next gate.
- Release-loop control: finish and freeze the package before any external submission; reuse applicable standing user authorization and ask for exact-hash approval only if actual tool review requires it. Bind the checkpoint immediately after every side effect. Bundle notarization plus the single planned QA into one exact-candidate gate when policy allows. A preflight/harness failure is not runtime evidence: fix the producer, create one replacement, and do not resubmit failed bytes. After two identical boundary failures, stop and diagnose; never create another candidate without a named invalidation reason.
- Evidence triage: once source/image/resource paths are mapped, stop repeating inventories that do not change an applicability decision. Resolve remaining `UNKNOWN` rows in one qualified-review batch or remove/replace the affected shipped components; do not label them clear. Keep the live board to one next gate and reuse evidence only for matching bytes, harness, and environment.
- Native QA admission: sample once after the exact package passes static gates and immediately before the single planned run. If ineligible, stop that native lane and advance independent work; do not poll or ask the user repeatedly while the environment is unchanged. Retry only after an observed environmental change and one fresh admission check; admission itself is never runtime PASS.
- Worktree discipline: follow `activeReleaseWorktree.path` in `CURRENT.json`; do not silently switch to the default checkout or infer candidate state from another dirty tree. Preserve unrelated worktrees and dirty files.
- Before freezing a candidate, synchronize and commit tracked `DerivedSources/NeAntikWebKitHost` files with their source counterparts; host packaging otherwise changes the tree after the preparation receipt and correctly refuses completion.
- QA producer boundary: `scripts/run-local-manager.sh --fixture` creates a local Dev app; it is not the signed owned-WebKit ZIP producer. Do not treat it as a fix for a notarized candidate or patch it by assumption. Identify or codify the actual package producer before creating replacement bytes.
- Local Dev bundle signing: when the wrapper relabels a copied release app as `.dev`, nested manager helpers must be ad-hoc signed in that disposable copy and the whole Dev app must pass deep strict verification. Never modify the source app to repair the fixture.
- Finish authorized local work to its acceptance gate. Diagnose two identical
  failures before retrying. Preserve real profiles, BrowserData and Keychain;
  QA uses owned synthetic roots and mock Keychain where required. Never put
  credentials/private traces in output, source, prompts or public artifacts.
- System Extensions: never repair `/Library/SystemExtensions` permissions or
  files. Use the framework/Finder lifecycle and the actual registered container;
  keep its file identity at the canonical path until deactivation completes.
  Preserve rollback by copying. Treat a required reboot as an external gate.

- Incremental runtime packaging must bind the framework nested in the actual
  signing input and staging copy to the selected link output; a loose sibling
  framework is not evidence of the shipped bytes. Validate DNR regex support
  through Chromium's own API/indexer; JavaScript RegExp accepts rules that
  exceed Chromium's2KiB RE2 budget.
