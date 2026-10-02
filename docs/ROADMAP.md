# Дорожная карта NeAntik

NeAntik остаётся нативным локальным приложением только для Mac с Apple
Silicon. Главный сценарий продукта:

> создать профиль -> при необходимости вставить прокси -> запустить браузер.

Дорожная карта не является обещанием дат. Каждая функция попадает в
публичный релиз только после тестов, Developer ID, Apple notarization,
stapling, Gatekeeper и проверки заново скачанных файлов.

## Свежая сверка Direct-релиза — 2026-09-28

GitHub API и `browser.free/api/release` повторно проверены: публичный релиз
остаётся `0.7.11 (74)`, ZIP SHA-256
`141ffacec0fb601a9e20fa722b348bc6eed444132efee9c72ab582b5645d3576`, DMG
SHA-256 `fa0489a57b790f51f3d8eea0fa2b4d816bf9a123559f9fd0da71e0ddab6521f4`.
Сайт верно удерживает загрузки выключенными (`canDownload=false`), пока
Chromium 153.0.8010.52 не обновлён до baseline 154.0.8037.58.

M154 source `a654841425914cbb703a2931e07b70a83aedbafd` проходит после group71
GN generation и четырёх header-dependency checks. Ошибка сборки на удалённых
`safe_browsing_prefs.h/.cc` исправлена точным восстановлением upstream prefs
и GN target; `safe_browsing_mode=0`, `SAFE_BROWSING_AVAILABLE=0` и
`SAFE_BROWSING_DOWNLOAD_PROTECTION=0` сохранены. Попытка #7 завершилась на
финальном ThinLTO-линке с отсутствующим ScreenAI symbol при выключенном
сервисе. Узкий group71 buildflag guard исправил ссылку: затронутый объект
скомпилировался, а одна инкрементальная цель `chrome` в том же output завершила
476/476 действий при `-j6`. Ограниченный GUI-smoke точного attempt8 app прошёл на `chrome://version`;
точные доказательства и blockers находятся в
`runtime/chromium-154-diagnostic-status.json`.

Текущая сборка использует уже установленный Stable Xcode 27.0 через
process-scoped `DEVELOPER_DIR`; выбранный глобально Xcode Beta 27.0 не
менялся. Это diagnostic SDK 27.0, а официальный M154 release toolchain
остаётся закреплённым на hermetic SDK 26.5/build 25F70, которого пока нет
локально; CIPD сообщает `Not logged in`, вход и загрузка пакета не
предпринимались. `gh auth status` подтверждён для `AffPapa` с scopes `repo` и
`workflow`; device OAuth повторять не нужно. Повторная проверка в
разрешённом macOS-контексте подтвердила четыре действующие signing identities,
включая Developer ID Application; профиль `neantik-notary` доступен, его
история читается. Кандидат не подписывался и в Apple не отправлялся. Это
снимает только прежнюю ошибку Keychain-доступа: текущие изменения не являются
release candidate и остаются заблокированы до закрытия точных runtime/toolchain
gates. M154 source contract/rebase plan и release-qualified postimage verifier
также пока отсутствуют; переход на публикацию не начинался.

## Текущий Direct release cycle

- Последний GitHub-релиз `0.7.11 (74)` заново проверен через GitHub API; публичные ZIP/DMG и SHA-256 совпадают с локальными. Sites подтверждает успешный deploy version 98 из `827e7231d0a756063425387d4c635d7066fa0424`; live `browser.free/api/release` отдаёт тот же ZIP SHA и `published-runtime-gated`, `canDownload=false`, `downloadUrl=null`, runtime/strict-coherence/owner-ready false из-за Chromium 153 ниже baseline M154. GitHub release body всё ещё указывает Sites version 92;
- предыдущий релиз `0.7.10` сохранён как rollback;
- публичный `0.7.11 (74)` исторически уточнял VoiceOver-контекст preview;
  локальный commit `66c590b` удаляет app-issued объявления, оставляя
  клавиатурное управление; публичный бинарный релиз этого не содержит;
- фоновый импорт профилей и папок, согласованность recovery при ошибке и
  progress-state preview восстановления реализованы и проверены в commit
  `66c590b`; этот commit ещё не включён в Direct-бинарный кандидат;
- lifecycle-проверка BrowserData отличает предел сканирования файлов/объёма от
  symlink и ошибок чтения; изменение проверено и закоммичено в `29b4325`;
- Chromium `153.0.8010.52` ARM64/Metal остаётся неизменным в manager-only
  срезах;
- новый manager-only preview списка прокси реализован локально, но Direct
  релиз блокирует security baseline Chromium `154.0.8037.58`;
- по решению владельца текущий локальный manager скрывает SwiftUI-контент,
  sheets и popovers от VoiceOver; в ранней ограниченной Dev.app-сессии были
  записаны проверки `Cmd+N`, `Cmd+Shift+N`, `Cmd+F`, Tab и Escape. При более
  позднем повторном запуске 25 сентября Dev.app не дошёл до UI из-за
  Development-данных неверного формата; поэтому прежний результат считается
  историческим и не заменяет повторный smoke на пригодном Dev.app или exact
  candidate. Системные меню macOS остаются системными; это изменение не входит
  в `0.7.11` и не включено в публичный релиз;
- runtime update и Direct-релиз разрешены пользователем; disposable M154
  mode-0 ARM64/Metal `chrome` target теперь линкуется (483/483 действий),
  executable сообщает `154.0.8037.58`, и временный manifest связывает его с
  точным diagnostic source diff. Это не release candidate: tree содержит 232
  изменённых tracked paths, 17 untracked inputs и неподдерживаемую SDK overlay.
  Headless `about:blank` smoke аварийно завершился в
  `TransformProcessType`. Более поздний GUI smoke использовал отдельный
  временный user-data-dir и локальную data: страницу; это подтверждает только
  запуск UI/renderer и выбор временного каталога, не A→B→A или recovery.
  Архивный suite прошёл 50/50; focused Enterprise policy/verdict suite
  прошёл 46/46 после подключения `FileUtilService` по Enterprise gate. До
  этого два `FileIsEncrypted` теста разрешали зашифрованный файл: M154
  utility-process регистрация сервиса была ограничена Safe Browsing download
  protection/ChromeOS, хотя Enterprise cloud analysis продолжал использовать
  архивный analyzer. Двухфайловый diagnostic patch проходит синтаксический
  `git apply --check` на чистом M154 `.58`, но зависит от локального
  `enterprise_archive_analysis` GN/Mojo gate, которого в clean source ещё нет;
  он не включён в owned release patchset, не прошёл clean replay/build и не
  доказывает обработку service crash/disconnect.
  Monolithic `unit_tests` ранее упал на ThinLTO-линковке с Safe Browsing
  символами, исключёнными mode 0.
  Safe Browsing и download protection остались выключены. Source/rebase,
  поддерживаемый toolchain, строгая runtime-изоляция, privacy-тесты, signing,
  notarization, Gatekeeper и release gates ещё не пройдены;
- в `/Applications/Xcode.app` уже была вторая копия Xcode 27.0
  (`27A266a`); выбранной остаётся Xcode Beta 27.0 (`27A5228h`). В текущем
  проходе Xcode не устанавливался и не переключался. Для отдельной
  диагностической сборки использовался SDK 27.0 второй копии, без SDK overlay;
  GN прошёл, затем завершились 12,743 из 49,767 оставшихся compile actions до
  намеренной остановки. Metal и ANGLE/Metal targets прошли без compiler/SDK
  errors. Это диагностическая сборка с test-only system-Xcode override, не
  release proof. Chromium M154 задаёт SDK 26.5 / `25F70` для официальных
  сборок, но upstream-инструкция говорит, что более новый SDK обычно работает.
  Установленная Xcode 27.0 уже пригодна для дальнейшей сборки и проверки; её
  полная квалификация как воспроизводимого release toolchain ещё не доказана.
  CIPD-пакет, закреплённый исходником, не установлен локально, а read-only
  запрос без CIPD-аутентификации не подтвердил его доступность. Xcode не
  устанавливался; дополнительная установка не является обязательным шагом;
- следующий релиз требует нового exact-source кандидата, полного набора
  release gates и проверки заново скачанных GitHub/site artifacts;
- последовательный diagnostic replay M154 подтвердил применение 11/11 owned
  runtime-групп после переноса двух зависимых Blink hunk-contexts на API/порядок
  инициализации M154. Эксперимент сохранён в
  `runtime/nevision-patches/ports/chromium-154.0.8037.58/port-experiment.json`;
  текущий canonical manifest намеренно остаётся на `152.0.7977.64`, и его
  release-ready проверка не является M154 evidence. После полного чистого DEPS
  sync официальный common overlay применился как 109/109 без fuzz/offset; 11
  owned-патчей применились на отдельной копии. Пиннутую M152 macOS series
  проверили на M154 common tree: 10 из 16 патчей применились, шесть требуют
  адаптации (`build-bindgen`, clang-version, Safe Browsing, `dsymutil`, bindgen
  target override и static bindgen). Safe Browsing patch требует восстановить
  Enterprise archive utility dependency под `enterprise_archive_analysis`.
  M154 macOS packaging/source-lock не собраны, behavior этих owned-патчей не
  компилировалось и не запускалось;
- свежая upstream GitHub API проверка не нашла M154 macOS packaging ref:
  `master` и latest release `ungoogled-chromium-macos` остаются на
  `152.0.7977.82-1.1` / commit `038db2b41f7aeb00bbceb2f5a56912b26eb5b284`.
  M154 macOS packaging нужно портировать; Linux-only common release этот слой
  не заменяет;
- незакоммиченные изменения или тестовый результат сами по себе не означают,
  что версия опубликована.

### Свежая проверка публичного релиза и локального состояния — 2026-09-28

Публичный GitHub Releases API по-прежнему возвращает immutable `v0.7.11` /
build `74`, source commit `fa3b03cbe122840ea308d2ecf19004a1128a1a06` и те же
четыре assets. ZIP (`191921946` bytes) имеет SHA-256
`141ffacec0fb601a9e20fa722b348bc6eed444132efee9c72ab582b5645d3576`; DMG
(`218376823` bytes) — `fa0489a57b790f51f3d8eea0fa2b4d816bf9a123559f9fd0da71e0ddab6521f4`.
Свежий GET `browser.free/api/release` подтверждает 0.7.11 / 74,
`published-runtime-gated`, `canDownload=false`, пустые download URLs и
Chromium 153.0.8010.52 ниже baseline 154.0.8037.58.

Публичная ветка `codex/neantik-workplaces` стоит на
`39e51de05c173c3f9261b894fd43f486b6429a0a`; локальная ветка находится на
`36db4e7a32882319cf6e1c49c4acd4ac59122cb7`, на девять коммитов впереди и без
коммитов, опубликованных только на сервере. `git status --short` показывает 16
изменённых/новых путей. Локальный `gh auth status` проверен повторно: сохранённые
токены AffPapa и mrdumay-source недействительны. Публичные GET-запросы доступны
без них; локальную CLI-авторизацию нельзя считать рабочим способом публикации.
Обе проверки относятся к состоянию на указанное время и не подтверждают новый
релиз.

## Выполнено в текущем manager pass

- UI-файлы Save/Open для metadata-only export/import и атомарное распределение
  импортированных профилей по папкам;
- зашифрованный экспорт/импорт только конфигурации профиля через
  AES-256-GCM и PBKDF2-HMAC-SHA256; Cookies, BrowserData и Keychain-секреты
  не экспортируются;
- lifecycle health center с lock/recovery/BrowserData size/last launch без
  raw path, PID и process arguments;
- privacy-панель aggregate media/permissions без device IDs и сырых значений;
- свежая подготовка маршрута перед каждой прокси-сессией без скрытого Direct
  fallback; запуск не переиспользует ручную проверку как разрешение;
- безопасная презентация прокси как «Маршрут подтверждён» без реального IP;
- provenance/quarantine для Downloads/Extensions с explicit-only политикой и
  Safe Browsing без ослабления;
- manager performance budgets и read-only runtime provenance card;
- фоновые snapshot/import/export; закрытие workspace отменяет незапущенную работу,
  но уже допущенная атомарная import-транзакция завершается и публикует результат
  после закрытия вызывающего окна;
- snapshot receipt показывает число сохранённых и пропущенных профилей;
- recovery notice доступен из Diagnostics и при пустом/unselected workspace;
- immutable `WorkspaceSnapshot` и allowlisted `WorkspacePublicSnapshotDTO`
  как безопасный внутренний контракт для будущих локальных read-only
  адаптеров; browser paths, credentials, IP и raw fingerprint evidence в DTO
  отсутствуют;
- компактный профильный UX: lifecycle, privacy, artifact provenance и runtime
  provenance свернуты в одну карточку «Диагностика»; подробности открываются
  только явно, а повторный `Последний запуск` удалён;
- A → B → A остаётся инженерной проверкой в раскрытых «Дополнительных
  проверках» и больше не поднимается в основное действие профиля;
- trigger policy формализует fail-closed поведение: только явный release-gate
  может автоматически запустить A → B → A; обычный запуск, runtime change и
  recovery-событие не создают браузерные процессы без явного действия;
- A → B → A readiness policy теперь требует фактическое состояние `.stopped`
  для каждого активного профиля и отказывает при checking, external lock или
  recoveryRequired; UI и coordinator используют один и тот же fail-closed
  контракт;
- compact diagnostics теперь переводит неизвестный Direct-status runtime в
  `unavailable`, а версию ниже security baseline — в `attention`, поэтому
  заблокированный кандидат или runtime с неполным provenance не может
  выглядеть для пользователя как готовый;
- privacy/release hardening: reachable Git history проверена на credential-файлы
  и известные форматы секретов без вывода содержимого совпадений;
- raw fingerprint reports остаются owner-only, максимум три файла и теперь
  ограничены 512 KiB на serialized report до записи на диск;
- synthetic public fingerprint corpus: 10 негативных и положительных cases;
  profile-isolation harness проверяет четыре synthetic storage sentinel-группы
  после SIGKILL/recovery и fail-closed leak mutation без Chromium, Keychain,
  пользовательских cookies/seeds, proxy credentials и raw network values;
- synthetic manager benchmark теперь имеет явные p50/p95 ceilings для 1/50/100
  профилей и отдельный `runtime_status=unverified`; эти цифры не выдаются за
  Chromium cold/warm или CPU/RAM evidence;
- exact-runtime performance contract и privacy-safe verifier для cold/warm
  start, idle CPU и idle memory с runtime version/hash, sample count и
  fail-closed budgets; фактическое измерение упакованного Chromium всё ещё
  остаётся `partial`/`unverified` до qualified producer и полного runtime
  evidence cycle; локальный ad-hoc кандидат не считается релизным доказательством;
- verifier получил отдельный `--require-verified` release mode: partial и
  unverified candidate reports нельзя случайно повысить до release evidence;
- для 0.7.9 зафиксированы 628 Swift-тестов в 70 suite и 684 Python-тестов
  (1 skipped); текущий кандидат прошёл 630 Swift-тестов в 70 suite и 684
  Python-тестов (1 skipped). Эти цифры не заменяют artifact/runtime/release gates.
- typed redacted support-bundle export: UI constructs only allowlisted aggregate
  data, writes a <=64 KiB JSON through the system Save dialog, and the independent
  verifier rejects unknown or sensitive fields.
- metadata-only local snapshots: explicit save/restore commands, last-three
  retention, fresh identities on restore, protected local files, and corruption
  tests; BrowserData, cookies, notes, identity seeds and Keychain stay out.
- diagnostics next-step UX: attention/unavailable states now explain one
  concise safe next action while the healthy state remains quiet; no raw paths,
  PIDs, IPs, device IDs or fingerprint values are shown.

## P1: public beta

В 0.7.8 уже есть summary свежести proxy-проверки. Он показывает состояние и
возраст результата, но не раскрывает IP или сетевые адреса.

В публичный 0.7.9 вошли два компактных quick-start шаблона («Работа»,
«Тестирование»), session-only отчёт о доступности browser-функций с привязкой к
свежему аудиту точного профиля/runtime и локальная read-only release-evidence
summary CLI. Отчёт не проверяет отдельный сайт, вход или бизнес-сценарии.
Опубликованный manager-only релиз 0.7.10 показывает safe preview snapshot restore
до commit и не меняет Chromium.

Explicit profile integrity repair assistant остаётся исследовательским
кандидатом: до реализации нужен отдельный UX и recovery threat review.

Snapshot save/restore и подготовка plain/encrypted export выполняются вне
UI-потока. После восстановления метаданных краткая read-only сводка остаётся в
«Диагностике». Preview snapshot restore выпущен в 0.7.10; публичный 0.7.11
добавлял речевой контекст, удалённый локальным commit `66c590b`; нативные
подписи элементов и keyboard actions сохранены.
Физическую клавиатуру нужно повторно проверить на exact candidate. См.
`docs/NEANTIK_GLOBAL_PRODUCT_PLAN_2026.md` и артефакты текущего цикла.

- воспроизводимые budgets для cold/warm start именно Chromium runtime, idle
  CPU/RAM и browser launch — manager-only ceilings выше уже закрыты отдельно,
  local ad-hoc candidate теперь даёт partial evidence, а public Chromium
  runtime остаётся unverified до source/signing/live gates;
- подключение будущего read-only локального адаптера к уже проверенному
  snapshot-контракту; сам сетевой API по-прежнему выключен и не входит в
  текущий Direct product surface;
- инвентаризация фоновых Chromium-запросов и решение вопроса защиты от
  фишинга и опасных загрузок; manager-поверхности уже описаны в
  `docs/NETWORK_REQUEST_INVENTORY.md`, а Chromium остаётся `unverified` до
  runtime evidence;
- подписанные инкрементальные обновления runtime с provenance, атомарным
  rollback и полным архивом восстановления.

## P2: production quality

- расширять каталог согласованных Apple Silicon-параметров только небольшими
  проверенными наборами, без независимой случайности между API;
- подтвердить строгую согласованность Canvas, WebGL, Audio, ClientRects,
  Client Hints, locale, timezone, WebRTC и параметров устройства;
- закрыть `unverified` инвентаризацию фоновых обращений Chromium и отдельно
  решить вопрос защиты от фишинга и опасных загрузок после точного runtime
  evidence cycle;
- рассмотреть подписанные инкрементальные обновления runtime только вместе с
  provenance, атомарным rollback и полным архивом для восстановления.

## Что сознательно не входит в продукт

Полный приоритизированный список из 30 пунктов находится в
`docs/NEANTIK_IMPROVEMENT_ROADMAP.md`.

- Electron, Tauri и обязательная установка стороннего Chrome;
- Windows/Linux-персоны на Apple Silicon;
- облачные аккаунты, команды, синхронизация и магазин прокси;
- automation/RPA и массовое управление сайтами;
- автоматически включённый или доступный из сети API, а также write-методы
  API/MCP/SDK для запуска браузера, изменения и удаления профилей; будущий
  read-only локальный адаптер возможен только как явно включаемый loopback
  процесс с аутентификацией и тем же allowlisted snapshot;
- JavaScript-инъекции fingerprint и случайный шум при каждом вызове API;
- функции или обещания обхода CAPTCHA, банов, антифрода и правил сторонних
  сервисов;
- заявления о полной анонимности или необнаружимости.

## Когда нужна тяжёлая проверка

- SwiftUI, текст, теги, поиск и другие manager-only изменения проверяются
  быстрыми unit/layout/privacy-тестами и не требуют ручного A -> B -> A на
  каждой итерации.
- Изменения Chromium, fingerprint, proxy/WebRTC/DNS политики или упаковки
  требуют свежего полного evidence.
- Любой публичный бинарный релиз получает один свежий A -> B -> A отчёт,
  привязанный к точному уже собранному и подписанному кандидату. Повторять
  проверку для неизменившихся байтов не нужно.
