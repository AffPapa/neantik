# NeAntik roadmap

The private maintainer checkpoint tracks live 1.0 qualification and is intentionally excluded from public source archives. Public acceptance criteria are in [NEXT_1_0_SLICES.md](NEXT_1_0_SLICES.md); this page records only public release facts and release goals.

## Current status

## Release 1.0 acceptance

Chromium перед каждой прокси-сессией выполняет свежую подготовку маршрута и не переиспользует ручную проверку. Для WebKit это не означает подтверждение маршрута окна.

- Qualify bundled Chromium and owned WebKit in one Direct Distribution app.
- Verify per-profile proxy routing, refusal without direct fallback, and recovery on the exact candidate.
- Publish the corresponding source, applicable license texts, notices, and recipient relink path.
- Measure profile isolation and privacy properties on signed candidate bytes. Do not claim anonymity or anti-fraud bypass.
- Sign and notarize ZIP and DMG, staple tickets, verify Gatekeeper, publish through GitHub Releases and browser.free, and recheck downloaded bytes.

## Исторический срез

Snapshot updated after publication: [0.9.3 (203)](https://github.com/AffPapa/neantik/releases/tag/v0.9.3), Chromium156.0.8078.80, is published public alpha. [`releases/v0.9.3.json`](../releases/v0.9.3.json) records downloaded-byte/Apple/scope evidence. At publication browser.free showed 0.9.3 (203) through Sites163; WebKit remains deferred. Earlier snapshots below remain history.

Snapshot updated after publication: [0.9.2 (202)](https://github.com/AffPapa/neantik/releases/tag/v0.9.2), Chromium156.0.8078.80, is published public alpha. [`releases/v0.9.2.json`](../releases/v0.9.2.json) records downloaded-byte/Apple/scope evidence. browser.free shows0.9.2 (202) through Sites162 with SEO161 retained; WebKit remains deferred. Earlier snapshots below remain history.

As recorded in [`releases/v0.9.0.json`](../releases/v0.9.0.json), [0.9.0 (140)](https://github.com/AffPapa/neantik/releases/tag/v0.9.0) is a public alpha for Apple Silicon using Chromium 156.0.8078.48. It includes system WebKit preview only; owned WebKit and its proxy are not qualified. This snapshot does not imply that 1.0 has shipped or assign a release date.
