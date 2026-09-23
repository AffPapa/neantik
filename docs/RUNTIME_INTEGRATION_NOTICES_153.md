# NeAntik Chromium 153 runtime notices

This Direct candidate embeds Chromium `153.0.8010.52` from the pinned official
Chromium source commit `78e5e45d4bb41035e17ea4da2cc257f496416ac9` together with
the pinned ungoogled Chromium 153 input layer. The macOS packaging is an owned
NeAntik port because the reviewed public ungoogled macOS packaging line stops
at `152.0.7977.82-1.1`.

The exact source and local-candidate evidence is bundled in
`NeAntikRuntimeEvidence/chromium-153-port-status.json` and
`NeAntikRuntimeEvidence/chromium-153-port-candidate.json`. The distributed
runtime is ARM64-only, uses the reviewed Metal configuration, and carries
Developer ID signing separately from this source notice.

Chromium-generated third-party notices and the SPDX document are bundled in
`NeAntikRuntimeCompliance/`. The source-port candidate record remains an
evidence record, not a claim of universal anti-fraud bypass or anonymity.
