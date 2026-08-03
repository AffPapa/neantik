# Supply chain Chromium runtime

Проверено: 30 июля 2026 года.

## Решение

NeAntik сохраняет нативный SwiftUI-менеджер и собственный узкий pipeline
сборки Chromium для Direct distribution. Репозиторий не принимает
непроверенные сторонние бинарники и не выдаёт source lock за доказательство
готового runtime.

Полезные открытые проекты используются только как инженерные источники идей:

| Проект | Что полезно | Граница |
|---|---|---|
| fingerprint-chromium | seed-based Canvas, Audio, WebGL, ClientRects, device и WebRTC patches | старые patch tags требуют переноса, review согласованности и новой сборки |
| ungoogled-chromium-macos | Apple Silicon build, packaging, entitlements и notarization patterns | packaging commit не доказывает совместимость NeAntik patchset |
| CloakBrowser | proxy/WebRTC consistency и A → B → A подход | чужой собранный runtime не распространяется вместе с NeAntik |
| Donut Browser / Wayfern | UX профилей, proxy flows и открытая архитектура | широкий web/Tauri UI и чужой fingerprint engine не копируются |
| Clearcote | прозрачные Chromium patches | macOS runtime должен быть доказан отдельно |

Основные источники:

- <https://github.com/adryfish/fingerprint-chromium>
- <https://github.com/ungoogled-software/ungoogled-chromium-macos>
- <https://github.com/CloakHQ/CloakBrowser>
- <https://github.com/zhom/donutbrowser>
- <https://www.clearcotelabs.com/>

## Публичный релиз 0.3.12

Опубликованный NeAntik `0.3.12` build `15` содержит Chromium
`150.0.7871.186`, ARM64, Metal. ZIP подписан Developer ID, нотарифицирован,
stapled и повторно проверен после скачивания. Его metadata и SHA-256 находятся
в `releases/`.

Эта опубликованная сборка не является доказательством ещё не выпущенных
изменений ветки `Unreleased`.

## Новый source contract и candidate

`runtime/chromium-150-source-contract.json` фиксирует:

- официальный Chromium tag/commit/tree `150.0.7871.186`;
- точные commits macOS packaging и common ungoogled-chromium;
- hashes критических upstream и NeAntik-owned inputs;
- статус `binaryBindingStatus: pending-new-build`.

`source-provenance.json` доказывает точное состояние нового source root.
`runtime-candidate-lock.json` имеет статус `source-qualified`: он подтверждает
исходники, но не бинарник. Promotion в канонический release lock требует:

1. сборку из точного source root;
2. `angle_enable_metal=true` в каноническом `args.gn`;
3. schema-3 runtime verification report;
4. совпадение source-contract, provenance, candidate-lock и binary hashes;
5. ARM64-only, nested signing, notices и SBOM gates;
6. GUI A → B → A и полный Direct release ladder.

Текущий candidate намеренно не promoted: установленному builder пока требуется
Metal Toolchain и новая production-сборка.

## Обязательные свойства fingerprint runtime

1. Один стабильный seed профиля, а не новый случайный шум при каждом вызове.
2. Изменения на уровне Chromium source, без JavaScript monkey-patching.
3. Единый согласованный Apple device tuple для UA, Client Hints, CPU, memory,
   screen, DPR и GPU.
4. Стабильность Canvas, Audio, WebGL и ClientRects между вкладками, процессами
   и перезапусками одного профиля.
5. Различимость профилей A и B без противоречий между API.
6. Proxy-derived timezone/locale только после успешной проверки прокси.
7. Fail-closed WebRTC/DNS policy без тихого direct-route fallback.
8. Точные source/binary hashes, licenses, SBOM, подпись и capability label.

Цель — приватность и разделение профилей. Проект не добавляет функции обхода
CAPTCHA, банов, антифрода, webdriver detection или правил площадок.

## Историческое доказательство

Chromium 144 использовался как раннее инженерное доказательство переноса
патчей и Metal-сборки. Он не является текущим публичным runtime и не может
использоваться как release candidate. Исторические source/build artifacts
сохраняются для воспроизводимости и не подменяют текущие Chromium 150 gates.

## Direct release boundary

NeAntik выпускается только через Direct Distribution для Apple Silicon.
Публичный бинарник должен пройти Developer ID, Hardened Runtime, notarization,
stapling, Gatekeeper, privacy scan, archive SHA и повторную проверку
скачанного файла. Секреты подписи остаются в Связке ключей локального trusted
builder и никогда не попадают в Git или CI.
