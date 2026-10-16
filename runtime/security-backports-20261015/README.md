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

Acceptance still requires source closure, compilation, relevant headed platform
and network checks, regression cases, exact signing/provenance and Direct
release qualification. The current branch security review remains empty and
refuses publication. This directory does not claim a new Chrome version or a
qualified security update.

Current development state: all eight complete patches have now been applied to
the owned source tree and all35 affected paths passed exact post-apply readback.
Prior bytes were preserved before modification; Chromium/V8 HEADs were kept.
The old compiled runtime is unchanged. A separate COW output is being prepared;
compilation and runtime qualification are still pending.
