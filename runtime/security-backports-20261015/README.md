# Chromium security backports — 15 October 2026

These are unmodified upstream Chromium/V8 patches for eight security fixes
missing from the source of NeAntik Chromium156.0.8078.12. The ordered manifest
records commit URLs, licenses, hashes, application roots and observed input
file hashes. Preserve each patch as a separate vector with its upstream tests.
The Core patch is the official M156 cherry-pick, avoiding a conflict from the
main-branch version. Chromium and V8 use the retained BSD licenses.

All eight patches applied and reverse-checked on isolated temporary copies of
the current source, including test files. No product checkout, compiled runtime
or public binary was changed by those checks. Source inclusion is not behavior
qualification. Desktop501886301 and Compositing556272421 already have the
production corrections in this base; do not apply them a second time.

Before applying, match every existing file hash, reject unexpected additions,
preserve the exact prior files and source/build state, then apply each full
patch in its manifest root. Build into a separate owned output, preserving the
working signed runtime. A future additive source contract must bind all changed
files and build inputs; never rewrite the historical font contract or lock.

Current development state: the eight complete patches are applied to35 paths
and linked in a separate jobs2 build. Exact source/tool inputs stayed unchanged;
a full postbuild FD observation and sixteen Developer ID Mach-O signatures are
retained in the additive `font-system-security-20261015-v1` contract.

The current source review binds all ten fixes to that exact new contract. It
still rejects the old131 contract. A headed research run passed nine bounded
DOM/V8/worker controls, including two deliberately broken controls. One
configured system-font page/worker smoke passed422 checks. These runs do not
cover every native upstream unit suite or qualify a final signed NeAntik app.
See `docs/evidence/security-backport-*-development.json` for exact limits.

Manager/updater admission now supports the complete new tuple and checks the
source-bound publication review. The successor is now published as NeAntik0.8.20(132): exact app enrollment/headed,
QA updater controls, doctor13/13, Apple ZIP/DMG, Gatekeeper, public bytes and
downloaded MCP passed in their stated scope. See `releases/v0.8.20.json`.
The frozen manifest describes the input stage, not current delivery status;
completion is recorded in the separate runtime verification and release report.
This is not a new upstream Chrome version or completed1.0. Historical runtime
contracts and old public assets are intact.
