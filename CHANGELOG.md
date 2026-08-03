# NeAntik changelog

## Direct 0.3.14 (17) — August 3, 2026

- Обычная проверка профиля сведена к одному действию и понятному итогу
  «пройдена / не пройдена». Техническая схема A → B → A, подробные поверхности
  и JSON-отчёт скрыты в раскрываемых подробностях; релизный режим и строгие
  fingerprint-gates не ослаблены.
- Профили получили локальные цветные иконки SF Symbols и теги. В боковой панели
  добавлены поиск по имени/тегам и фильтр по тегу, чтобы списком было удобно
  пользоваться при десятках и сотнях профилей. Старые профили мигрируют без
  смены UUID, BrowserData, fingerprint seed или данных Связки ключей.
- Запуск больше не создаёт пустую папку BrowserData для уже удалённого профиля
  до проверки tombstone/lease. Горячий путь запуска перестал повторно
  перечислять и укреплять все диагностические логи; необходимые закрытые
  каталоги координации по-прежнему создаются безопасно.
- Временные каталоги синтетических A → B → A профилей удаляются после проверки,
  только если они остались пустыми; пользовательские данные рекурсивно не
  очищаются.
- Защищённая релизная проверка A → B → A теперь запускается и завершается
  автоматически. Невалидный результат проверяется до подписи и не расходует
  одноразовое доказательство выпуска; ручные клики, Command-Q и Return больше
  не нужны.
- Manager-only упаковка синхронизирует свежий security baseline с evidence
  внутри `.app`. Однокнопочный выпуск показывает четыре коротких этапа, а
  подробную диагностику сохраняет отдельно вместо повторения сотен строк.
- В корне проекта добавлен постоянный `Release-NeAntik.command`: он сам читает
  текущую версию, готовит ZIP и DMG, а уже существующие финальные файлы
  проверяет вместо повторной notarization. Имя команды больше не меняется при
  каждом обновлении.
- Read-only инспектор notarization больше не считает служебный `.DS_Store`
  Finder опасной транзакцией. Этот файл не читается как release input; состояние,
  подписи, hashes и Apple receipts по-прежнему проверяются fail-closed.
- Проверка готового fingerprint evidence получила режим `--verify-only`,
  который не перезаписывает release-файлы и не может вмешаться в уже начатую
  notarization-транзакцию.

- Только новые профили получают `issuanceVersion=2`: системный CSPRNG
  равномерно выбирает один из 780 903 144 seed в четырёх проверенных
  Apple Silicon-когортах. Валидные старые, импортированные и мигрированные
  профили сохраняют seed без автоматической ротации; legacy high-bit и
  коллизии исправляются один раз с сохранением аппаратной когорты.
- Direct-профили не передают Chromium географические overrides. Прокси-профиль
  с устаревшим или недоказанным контекстом теперь блокирует запуск и просит
  повторить проверку, не меняя отпечаток молча. Raw seed-код скрыт из обычного
  UI, а одноимённые профили различимы по локальному номеру.
- Профиль «Без прокси» теперь явно запускается с `--no-proxy-server` и не
  наследует системный HTTP proxy/PAC/autodetect macOS; альтернативные proxy
  switches не могут попасть во внутренние дополнительные аргументы.
- Строгий fingerprint gate теперь измеряет `WorkerNavigator.deviceMemory` и
  требует согласия с main realm и Apple device tuple. Старые отчёты остаются
  честным public-alpha evidence, но больше не могут получить production PASS
  без worker memory; версия строгого audit-контракта поднята до schema 7,
  включая ECMA-402 locale core для script/region coherence.
- Пассивное наблюдение за внешними/recovery-процессами приостанавливается,
  когда NeAntik неактивен, и полностью пересобирается после возврата или
  пробуждения Mac; управляемые браузеры и fail-closed lease не затрагиваются.
- Отмена проверки прокси теперь немедленно завершает её `curl`-процесс, а
  повторное копирование credentials отменяет старые таймеры очистки буфера.
- Поиск preferred runtime прекращается после первого пригодного Chromium и
  больше не хеширует все установленные браузеры перед обычным запуском.
- Direct release теперь требует свежий GUI A → B → A report, связанный с
  конкретным упакованным `.app`; fingerprint evidence отвергает любые лишние
  поля и обезличивает имена/UUID профилей перед сохранением release-копии.
- Публичный fingerprint summary больше не содержит profile seed,
  `identityCode` или сырые значения browser surfaces. Проверяемая локальная
  копия использует синтетические role IDs, остаётся приватной, а менеджер
  автоматически хранит не более трёх последних raw-отчётов.
- Профиль блокируется атомарной owner-scoped lease до запуска Chromium.
  Повреждённый, нечитаемый или подменённый lock теперь переводит профиль в
  fail-closed recovery, а stale lock удаляется только после доказанного
  отсутствия процесса с тем же `BrowserData`.
- Website handoff больше не включает raw fingerprint/storage JSON с
  cookie-токенами, именами профилей или локальными путями.
- Новый privacy gate проверяет staging и точный website handoff ZIP на
  локальные пути, profile seed, raw fingerprint values и proxy credentials,
  не выводя найденные значения в диагностике.
- Версия отчёта A → B → A поднята до schema 2. Публичный alpha gate и строгий
  production gate теперь явно разделены: старые корректные отчёты остаются
  пригодны как alpha evidence, но не могут подтверждать строгую
  production-согласованность.
- Строгая проверка измеряет повторные вызовы Canvas, WebGL pixels и ClientRects,
  чтобы выявлять хаотический шум внутри одной страницы.
- Добавлена сверка main realm с Web Worker/OffscreenCanvas для Canvas, WebGL,
  UA, Client Hints, platform, languages, timezone, locale, CPU и графических
  параметров.
- Добавлены проверки CSS media queries для размеров экрана и DPR, а также
  WebGL shader precision. Несогласованные или недоступные поверхности теперь
  честно блокируют только строгий production gate, не маскируясь зелёным
  результатом публичного alpha.
- Swift-классификатор и независимый Python release verifier используют один
  набор обязательных полей и одинаковые правила cross-realm consistency.
- Для proxy-профилей DNS-prefetch, Async DNS и DoH блокируются вместе с
  fail-closed resolver rules; QUIC и непроксированный WebRTC UDP остаются
  выключены. Direct-профили теперь ограничивают WebRTC публичным интерфейсом,
  не отключая обычные звонки полностью.
- Окно проверки теперь отдельно показывает public-alpha и strict-production
  статус и объясняет по-русски schema, повторные вызовы, worker и CSS
  coherence-проблемы вместо общего вводящего в заблуждение сообщения.
- Профиль сохраняет версию неизменяемого Apple device catalog и рассчитанный
  tuple ID. Неизвестная версия или tuple, не соответствующий seed, блокируется
  вместо тихой смены отпечатка; strict-отчёт связан с catalog v1.
- Перед изменением `profiles.json` сохраняется приватная предыдущая ревизия.
  Если основной JSON повреждён, NeAntik восстанавливает проверенную ревизию,
  сохраняет отвергнутый файл в закрытой папке `Recovery` и не трогает cookies,
  сессии и остальной BrowserData. Symlink-подмена backup блокируется.
- Runtime audit wrapper теперь передаёт поддерживаемый CLI-режим
  `--manager-app /absolute/path/to/NeAntik.app`, чтобы schema 2 evidence можно
  было связать с точной тестируемой сборкой менеджера.
- Закрыт supply-chain дефект Chromium patch verifier: вложенный `build/src`
  больше не может молча пропустить патч с сообщением `Skipped patch` и вернуть
  exit 0. Семь owned patches применяются одной транзакцией, проверяются по 21
  postimage и привязываются к source stamp SHA самого manifest.

## Direct 0.3.13 (16) — July 30, 2026

- Подготовлен быстрый Direct release path после установки Apple Metal Toolchain:
  local candidate теперь собирается с version/build 0.3.13 (16), embedded
  Chromium evidence переснимается как Metal runtime report, а source-qualified
  schema 4 runtime lock и compliance/SPDX binding встраиваются в candidate app
  перед release gate.
- Убран последний contiguous `NeVision Browser Framework` compatibility string
  из бинаря менеджера без удаления runtime compatibility с существующим
  Chromium bundle path.
- Добавлены 0.3.13 ZIP/DMG operator wrappers. Hosted ZIP verification теперь
  использует строгую связку final archive, checksum sidecar, candidate
  manifest, GUI fingerprint evidence и public attestation; legacy
  archive-only mode остаётся только для исторических 0.3.12 артефактов.
- Public download wrappers переведены на
  `https://affpapa.org/neantik/downloads/`.
- Ограничение сохраняется: 11 compiled Chromium runtime paths всё ещё содержат
  legacy `NeVision` names. Для strict production branding нужна полная
  Chromium runtime rebuild.

## Direct 0.3.12 (15) — July 28, 2026

- Исправлена безопасная миграция данных NeVision → NeAntik: при ошибке
  перемещения приложение продолжает работать со старой папкой, не скрывая
  профили и не создавая пустое хранилище поверх них.
- Исправлена миграция паролей прокси в Связке ключей: старый секрет удаляется
  после переноса, удаление профиля очищает оба пространства имён, ошибки
  откатываются без потери секрета.
- Восстановлено наблюдение за Chromium после повторного запуска менеджера;
  неизвестный живой процесс теперь блокирует двойной запуск безопасным образом,
  а завершившийся процесс автоматически освобождает профиль.
- Вывод Chromium больше не сохраняется целиком в лог менеджера; остаются только
  короткие диагностические события без URL, cookies и данных прокси.
- Основные действия доступны в окне от 760×520, длинные имена ограничены,
  редактирование запущенного профиля заблокировано, интерфейс и подсказки
  переведены на русский.
- Direct-телеметрия оставлена выключенной до готовности сервера и политики;
  постоянный идентификатор установки удалён из Direct-клиента.
- Proxy test передаёт credentials только через stdin-конфиг curl, корректно
  экранирует кавычки, обратные слеши и управляющие escape-последовательности;
  неоднозначный логин с двоеточием не принимается.
- Release gates теперь запрещают повтор версии/build, перезапись архива,
  неправильное публичное имя `.app`, fail-open notarization/Gatekeeper и
  fingerprint-отчёт, не связанный со свежими SHA конкретного приложения.
- Публичный manager очищен от legacy bundle code (`NANT`/`APPLNANT`), добавлены
  проверки русского UI, branding residue и физического immutable release
  каталога сайта.
- Публичный alpha использует Chromium 150.0.7871.186 ARM64 Metal. Строгая
  production-согласованность fingerprint и полная очистка внутреннего бренда
  Chromium остаются отдельной задачей следующей пересборки движка.

## Direct 0.3.11 (14) — July 27, 2026

- Renamed the product, native manager, bundle identifiers, icons, telemetry
  keys, public copy, and Direct packaging to NeAntik.
- Added first-run migration from the old local Application Support directory to
  the new NeAntik directory so existing profiles are preserved.
- Added Keychain fallback for legacy proxy passwords, then stores new secrets
  under the NeAntik service namespace.
- Rebuilt the local integrated Direct app as `NeAntik-Integrated.app` with the
  Chromium 150 ARM64 Metal runtime bundled inside.
- Moved the public product route to `/neantik/`; the old `/nevision/` route is
  kept only as a compatibility redirect.

## Direct 0.3.10 (13) — July 27, 2026

- Shipped the first notarized Direct public alpha archive for Apple Silicon:
  `NeAntik-0.3.10-arm64-notarized.zip`.
- Verified Apple notarization, stapling, Gatekeeper assessment, hosted HTTPS
  download, and SHA-256 for the Direct archive.
- Fixed the public-alpha runtime signing fallback so nested Chromium `.dylib`
  files are signed with Developer ID and secure timestamps before notarization.
- Recreated the Chromium 150 build root after reboot and restored the missing
  generated `build/config/gclient_args.gni` from Chromium `DEPS`.
- Verified Chromium 150 GN generation for the patched ARM64 Direct runtime:
  `30841` targets from `4684` files.
- Corrected the Chromium 150 runtime lock so the current state is explicit:
  GN-ready, Metal Toolchain missing, full binary build and GUI A → B → A still
  pending.
- Added a safe Chromium 150 resume script for the already prepared build root:
  it checks Metal, preserves the patched source tree, regenerates GN files and
  resumes `ninja` with bounded parallelism.
- Hardened profile identity seeds so NeAntik never sends values outside the
  current runtime's positive signed-32-bit fingerprint switch range.
- Added one-time repair for older high-bit seeds, including collision repair,
  so legacy profiles keep stable but runtime-compatible identities.
- Made the production fingerprint gate stricter: browser-mode release evidence
  now requires runtime version, valid signature, stable profile sequence,
  complete Canvas/WebGL/Audio/ClientRects/context surfaces, and different WebGL
  pixels between profiles.
- Kept corrupted `profiles.json` fail-closed so a damaged metadata file cannot
  be silently overwritten by a new profile save.
- Added regression coverage for launch arguments, legacy seed migration,
  production fingerprint qualification, rollback, and local profile storage
  safety.

## Direct 0.3.10 engineering build (13) — July 25, 2026

- Added one reviewed Apple Silicon device catalog for GPU, CPU, exposed
  memory, screen, DPR, and macOS Client Hints.
- Fixed Client Hints so a profile seed cannot claim a Chromium patch version
  different from the running binary.
- Added a private loopback audit origin so secure-context surfaces such as
  `navigator.deviceMemory` and high-entropy Client Hints are measured offline.
- Disabled unnormalized WebGPU adapter access in fingerprint mode and added a
  WebGPU policy probe.
- Rebuilt the integrated engineering ZIP without AppleDouble metadata so a
  fresh extraction preserves strict code-sign verification.
- Added a legacy profile-metadata repair tool and regression coverage for
  unsigned seeds from older `0.3.7` profiles.
- Added classic `PkgInfo` files to Direct and Store bundles and locked that in
  release verification.
- Added runtime-specific cross-field tuple validation to the production
  A → B → A gate.
- Verified the rebuilt ARM64 Metal runtime and a diagnostic A → B → A run;
  normal GUI WebGL evidence and the Chromium 150 security rebase remain
  mandatory before public Direct distribution.

## Direct 0.3.9 (12) — July 25, 2026

- Added optional anonymous product statistics, disabled by default.
- Added a public privacy-thresholded dashboard and JSON API.
- Added aggregate profile, proxy-profile, browser-launch, edition, and
  active-installation metrics without browsing or proxy details.
- Added a random Keychain-backed installation identity, one-time event
  deduplication, 35-day activity retention, and retryable consent revocation.
- Updated the privacy manifest and App Store privacy metadata.
- Kept all browser, proxy, profile, and fingerprint data out of telemetry.

## Store 0.1.4 (5) — July 25, 2026

- Added the same optional, off-by-default aggregate statistics control.
- Added public-statistics access from the native UI.
- Declared Device ID and Product Interaction for Analytics, not linked to the
  user and not used for tracking.

## Direct 0.3.8 (11) — July 25, 2026

- Hardened stable profile identity migration and collision repair.
- Added rollback and symlink defenses around local profile lifecycle.
- Bound release evidence to the exact runtime binary and source lock.
- Added a fail-closed Chromium security baseline.

## Direct 0.3.7 (10) — July 25, 2026

- Verified real Blink cookie and localStorage isolation and persistence.
- Hardened duplicate profile-ID and fingerprint-seed repair.

## Direct 0.3.6 (9) — July 25, 2026

- Added strict production-qualified fingerprint evidence rules.
- Hardened Store provisioning and metadata validation.

## Direct 0.3.5 (8) — July 25, 2026

- Moved NeAntik branding into the pinned Chromium source build.
- Completed a Metal-enabled ARM64 integration build and headless A → B → A
  diagnostics while keeping the GUI production gate explicit.

## Direct 0.3.4 (7) — July 25, 2026

- Packaged the native manager and NeAntik Browser into one Direct app.
- Added notices, SPDX SBOM, provenance, and integrated release verification.

## Direct 0.3.3 (6) — July 25, 2026

- Added the branded NeAntik Browser integration and automatic compatible
  runtime discovery.

## Direct 0.3.2 (5) — July 25, 2026

- Added stricter fingerprint-surface availability checks and a developer audit
  CLI.
- Hardened proxy testing against curl configuration and direct fallback.

## Direct 0.3.1 (4) — July 25, 2026

- Hardened process recovery, local file permissions, proxy validation, and
  fingerprint-audit isolation.

## Direct 0.3.0 (3) — July 24, 2026

- Added the local three-pass A → B → A fingerprint verification flow.
- Added runtime capability and supply-chain verification.

## Direct 0.2.0 (2) — July 24, 2026

- Added stable per-profile identity, proxy-location consistency, and runtime
  awareness.

## Direct 0.1.0 (1) — July 24, 2026

- First native SwiftUI MVP with persistent profiles, isolated browser data,
  proxy configuration, Keychain credentials, and Apple Silicon-only builds.
