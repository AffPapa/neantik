# Supply chain Chromium runtime

Историческая проверка: 25 сентября 2026 года. Актуальное состояние ниже.

### Current release and toolchain checkpoint — 29 September 2026

Fresh GitHub and `browser.free/api/release` reads still identify immutable
NeAntik `0.7.11` / build 74 / Chromium `153.0.8010.52`; the API is
`published-runtime-gated` and `canDownload=false`. Sites is now version 98
(the references to version 95 below are historical). Chrome 154
`154.0.8037.58` remains the latest broad Stable Mac build; Chrome 155 is only
Early Stable for a small percentage, so the active port target remains M154.

The exact M154 port remains diagnostic-only. Upstream macOS packaging source
was identified at `ungoogled-chromium-macos` tag `154.0.8037.57-1.1`
(`3241dc9cacee393621d277ec936376072f0cb3c5`), pinning common source
`800d0bb5078472e4442c1fd73373172754a60939`; Chromium `.58` is a direct child
of `.57` with only `chrome/VERSION` changed. The clean upstream replay applied
all 109 common and 20 macOS patches to `.58`; the full-DEPS source lock covers
240 dependencies and the ordered owned replay records 75 groups. A diagnostic
source-input manifest now binds that tree, but the NeAntik release source
contract is still missing. Stable Xcode 27 is installed and was used for
diagnostics, but it is not yet pinned as the release toolchain; the hermetic
SDK package is unavailable in this authenticated context. Build/report/
integrated-release scripts fail closed on missing evidence. `gh auth status`
reports invalid local CLI
tokens; connector read access does not authorize Release asset uploads. The
Developer ID identities and `neantik-notary` profile are readable in the
permitted macOS context, but no new candidate exists to sign or notarize.

## Актуальный менеджерский release record (24 сентября 2026)

Свежая read-only проверка GitHub Release и browser.free API подтвердила
NeAntik 0.7.11/build 74 и Chromium 153.0.8010.52 ARM64/Metal. Source commit —
`fa3b03cbe122840ea308d2ecf19004a1128a1a06`; записанный ZIP SHA-256 —
`141ffacec0fb601a9e20fa722b348bc6eed444132efee9c72ab582b5645d3576`.
GitHub asset metadata matches recorded ZIP/DMG hashes. На момент публикации
Sites version 92 отвечала `canDownload=true`; текущая Sites version 95 и live
API на 25 сентября сообщают `published-runtime-gated`, `canDownload=false` и
`downloadUrl=null` из-за обновлённого Chromium baseline. Runtime остаётся
`securityCurrent: false`, strict production fingerprint coherence — incomplete.

Официальное обновление Chrome Stable 154 для desktop опубликовано 22 сентября
2026 года и содержит security fixes: <https://chromereleases.googleblog.com/2026/09/stable-channel-update-for-desktop_0856730748.html>.
Поэтому закреплённый Chromium 153 ниже текущего repository security baseline.
Пользователь разрешил обновить Chromium и выпустить Direct-релиз, но новый
runtime ещё не собран и не прошёл gates. Поэтому менеджерский preview пока
нельзя публиковать. Это документальное обновление baseline не меняет Chromium.

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

## Исторический публичный baseline на 21 сентября

На дату этого исторического анализа публичный GitHub-релиз NeAntik был
`0.7.3` build `66` с Chromium `153.0.8010.36`, ARM64, Metal. Его ZIP и DMG
были опубликованы с SHA-256 sidecar-файлами. Локальный release catalog намеренно
не подменяется этой записью: текущий checkout содержит manager candidate
`0.3.20 (23)` и не является исходным commit публичного `0.7.3`.

Этот runtime был ниже тогдашнего repository security baseline `153.0.8010.52`
и сейчас ниже `154.0.8037.58`; он не является доказательством актуальности
security fixes. Подпись,
notarization и stapling подтверждают происхождение артефакта, но не заменяют
обновление Chromium. Эта опубликованная сборка также не является
доказательством ещё не выпущенных изменений текущей ветки.

## Новый source contract и candidate

`runtime/chromium-152-source-contract.json` фиксирует:

- официальный Chromium tag/commit/tree `152.0.7977.64`;
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

Текущий source candidate намеренно не promoted до завершения новой
ARM64/Metal-сборки и свежей бинарной/GUI-проверки. Опубликованный Chromium
153.0.8010.36 runtime нельзя повторно использовать для следующего релиза как
доказательство прохождения baseline: официальный Chrome
Stable для macOS от 17 сентября 2026 года содержал Chromium
`153.0.8010.52/.53` и 16 исправлений безопасности; это историческое значение,
с 24 сентября superseded версией 154.0.8037.58 и 108 исправлениями.

Privacy-oriented build использует `safe_browsing_mode=0`: обращения к Google
Safe Browsing не включены, но runtime не предоставляет встроенную замену
защите от фишинга, вредоносных сайтов или опасных загрузок. Это публичное
ограничение релиза, а не скрытая security-гарантия.

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
сохраняются для воспроизводимости и не подменяют текущий security baseline
153. Локальный Chromium 152-кандидат остаётся полезным только как
инженерный reference и заблокирован для публичного Direct-релиза до
появления reviewed macOS packaging chain для baseline.

## Direct release boundary

NeAntik выпускается только через Direct Distribution для Apple Silicon.
Публичный бинарник должен пройти Developer ID, Hardened Runtime, notarization,
stapling, Gatekeeper, privacy scan, archive SHA и повторную проверку
скачанного файла. Секреты подписи остаются в Связке ключей локального trusted
builder и никогда не попадают в Git или CI.
