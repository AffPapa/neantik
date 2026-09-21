# Дорожная карта NeAntik

NeAntik остаётся нативным локальным приложением только для Mac с Apple
Silicon. Главный сценарий продукта:

> создать профиль -> при необходимости вставить прокси -> запустить браузер.

Дорожная карта не является обещанием дат. Каждая функция попадает в
публичный релиз только после тестов, Developer ID, Apple notarization,
stapling, Gatekeeper и проверки заново скачанных файлов.

## P0: следующий Direct release

- получить проверенную пару исходников Chromium 153 и macOS packaging. Общий
  ungoogled-релиз уже содержит `153.0.8010.52`, но публичный macOS packaging
  пока не поднялся выше `152.0.7977.82-1.1`;
- создать новый source contract только из точных upstream commit/tag и
  перенести все release-required NeAntik patch groups с нулевым fuzz;
- после отдельного разрешения пересборки выполнить ARM64/Metal build,
  source/binary provenance, runtime, profile-isolation, network-reality и
  GUI A -> B -> A gates;
- только после этого подписать, notarize, staple, проверить Gatekeeper,
  подготовить GitHub/AffPapa Direct artifacts и доказать повторную загрузку,
  checksums, live-переключение и rollback.

До появления точного macOS Chromium 153 source pair и разрешения пересборки
эти пункты остаются единственными незавершёнными P0-гейтами. См.
`docs/RUNTIME_SECURITY_REBASE_153.md`.

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
- полный Swift gate: 569 тестов в 61 suite, включая manager, privacy,
  isolation, lifecycle, provenance и performance проверки.

## P1: public beta

P1 ниже содержит только долгосрочные улучшения после разблокировки runtime;
перечисленные выше manager-функции больше не считаются незавершёнными.

- воспроизводимые budgets для cold/warm start именно Chromium runtime, idle
  CPU/RAM и browser launch;
- immutable workspace snapshot как внутренний контракт будущих локальных
  адаптеров, при сохранении allowlist DTO без browser paths, credentials, IP и
  fingerprint evidence;
- отдельная инвентаризация фоновых Chromium-запросов и решение вопроса
  защиты от фишинга и опасных загрузок;
- подписанные инкрементальные обновления runtime с provenance, атомарным
  rollback и полным архивом восстановления.

## P2: production quality

- расширять каталог согласованных Apple Silicon-параметров только небольшими
  проверенными наборами, без независимой случайности между API;
- подтвердить строгую согласованность Canvas, WebGL, Audio, ClientRects,
  Client Hints, locale, timezone, WebRTC и параметров устройства;
- инвентаризировать фоновые обращения Chromium и отдельно решить вопрос
  защиты от фишинга и опасных загрузок;
- рассмотреть подписанные инкрементальные обновления runtime только вместе с
  provenance, атомарным rollback и полным архивом для восстановления.

## Что сознательно не входит в продукт

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
