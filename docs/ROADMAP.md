# NeAntik roadmap

The private maintainer checkpoint tracks live 1.0 qualification and is intentionally excluded from public source archives. Public acceptance criteria are in [NEXT_1_0_SLICES.md](NEXT_1_0_SLICES.md); this page records only public release facts and release goals.

## Current status

The public baseline is [1.1.0 (214)](https://github.com/AffPapa/neantik/releases/tag/v1.1.0) for Direct Distribution. It bundles Chromium 157.0.8103.79 and WebKit. See [the release record](../releases/v1.1.0.json) for published assets and validation scope.

## Release 1.0 acceptance

Свежая автоматическая подготовка выполняется перед каждой прокси-сессией Chromium: она заново проверяет прокси, получает через него данные для часового пояса и языка и не переиспользует ручную проверку из редактора. Эта предварительная проверка не измеряет маршрут HTTP/DNS-запросов окна Chromium: `runtimeRoute` остаётся `unverified`. Для WebKit в 1.0.0 маршрут TURN/TLS проверен через тестовый HTTP-прокси.

- Qualify bundled Chromium and owned WebKit in one Direct Distribution app.
- Verify per-profile proxy routing, refusal without direct fallback, and recovery on the exact candidate.
- Publish the corresponding source, applicable license texts, notices, and recipient relink path.
- Measure profile isolation and privacy properties on signed candidate bytes. Do not claim anonymity or anti-fraud bypass.
- Sign and notarize ZIP and DMG, staple tickets, verify Gatekeeper, publish through GitHub Releases and browser.free, and recheck downloaded bytes.

## Исторический срез

Snapshot after publication: [1.1.0 (214)](https://github.com/AffPapa/neantik/releases/tag/v1.1.0) is recorded on GitHub. [The release record](../releases/v1.1.0.json) lists asset hashes and the scope of verification.

Snapshot after publication: [1.0.0 (211)](https://github.com/AffPapa/neantik/releases/tag/v1.0.0) was available on GitHub and browser.free (Sites 178). [The release record](../releases/v1.0.0.json) includes asset hashes, source delivery and WebKit qualification.

Snapshot updated after publication: [0.9.5 (205)](https://github.com/AffPapa/neantik/releases/tag/v0.9.5), Chromium 156.0.8078.80, was the public-alpha baseline at publication. [`releases/v0.9.5.json`](../releases/v0.9.5.json) records the exact asset hashes and qualification scope. At publication browser.free showed 0.9.5 (205) through Sites 174; the effective external proxy route remains unverified and WebKit remains deferred.

Snapshot updated after publication: [0.9.2 (202)](https://github.com/AffPapa/neantik/releases/tag/v0.9.2), Chromium156.0.8078.80, was published as public alpha. [`releases/v0.9.2.json`](../releases/v0.9.2.json) records its release asset digests and verification scope. At that snapshot, browser.free showed 0.9.2 (202) through Sites162. WebKit remained deferred. This historical snapshot is retained separately from the current 0.9.4 release.

As recorded in [`releases/v0.9.0.json`](../releases/v0.9.0.json), [0.9.0 (140)](https://github.com/AffPapa/neantik/releases/tag/v0.9.0) is a public alpha for Apple Silicon using Chromium 156.0.8078.48. It includes system WebKit preview only; owned WebKit and its proxy are not qualified. This snapshot does not imply that 1.0 has shipped or assign a release date.
