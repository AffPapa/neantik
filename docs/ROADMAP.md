# Дорожная карта NeAntik

NeAntik остаётся нативным локальным приложением только для Mac с Apple
Silicon. Главный сценарий продукта:

> создать профиль -> при необходимости вставить прокси -> запустить браузер.

Дорожная карта не является обещанием дат. Каждая функция попадает в
публичный релиз только после тестов, Developer ID, Apple notarization,
stapling, Gatekeeper и проверки заново скачанных файлов.

## P0: следующий Direct release

- выпустить manager-only candidate `0.7.5 (68)` на уже опубликованной и
  проверенной runtime-цепочке Chromium `153.0.8010.52` без пересборки Chromium;
- повторить для нового exact candidate profile-isolation, network-reality и
  GUI A -> B -> A gates, затем подписать, notarize, staple, проверить
  Gatekeeper, GitHub/AffPapa artifacts и повторную загрузку;
- отдельный Chromium rebuild остаётся за пределами этого manager-релиза и
  требует собственного source/binary provenance cycle.

Если signing/notary credentials недоступны в текущем macOS-сеансе, исходник и
тесты можно подготовить, но публикация должна остановиться до запуска
проверенного release-командного файла в обычной пользовательской сессии.

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
- полный Swift gate: 598 тестов в 65 suite, включая manager, privacy,
  isolation, lifecycle, provenance, responsive layout и performance проверки.
- typed redacted support-bundle export: UI constructs only allowlisted aggregate
  data, writes a <=64 KiB JSON through the system Save dialog, and the independent
  verifier rejects unknown or sensitive fields.
- metadata-only local snapshots: explicit save/restore commands, last-three
  retention, fresh identities on restore, protected local files, and corruption
  tests; BrowserData, cookies, notes, identity seeds and Keychain stay out.

## P1: public beta

P1 ниже содержит только долгосрочные улучшения после разблокировки runtime;
перечисленные выше manager-функции больше не считаются незавершёнными.

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
