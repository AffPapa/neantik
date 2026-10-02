# NeAntik — глобальный план продукта и следующего цикла

Дата ревизии: 25 сентября 2026 года.

Этот документ объединяет предыдущие roadmap, runtime/security handoff,
исследования по fingerprint/privacy и свежий анализ официальной документации
Chromium/W3C и публичных материалов конкурентов. Он является рабочим планом,
а не обещанием универсального обхода антифрод-систем.

## 1. Продуктовая формула

NeAntik — локальный macOS-браузер с независимыми профилями для раздельной
работы с сайтами и собственными defensive-тестовыми стендами.

Главный путь должен оставаться коротким:

> создать профиль → при необходимости добавить прокси → запустить.

Всё остальное подчиняется четырём правилам:

1. Простые действия видны сразу, инженерные проверки открываются явно.
2. Профиль — это согласованный контейнер состояния, а не набор случайных
   переключателей.
3. Любой статус, который нельзя подтвердить, показывается как неизвестный или
   требующий внимания, а не как «готово».
4. Секреты, реальные cookies, реальные fingerprint-значения, IP и сетевые
   адреса не попадают в публичные отчёты, UI-сводки и тестовые fixtures.

## 2. Что уже есть на исходной точке

Публичный baseline текущего цикла:

- NeAntik 0.7.11, build 74 (24 сентября 2026; tag and GitHub assets are
  recorded in release evidence; a later browser.free API check on 25 September
  was saved, but a fresh live recheck in this continuation is unavailable);
- Direct Distribution для Apple Silicon;
- встроенный Chromium 153.0.8010.52 ARM64 Metal;
- локальные профили, папки, поиск, теги, snapshots, безопасное копирование;
- metadata-only import/export через системные диалоги;
- 0.7.7 исправляет ложные статусы lock/recovery и диагностику VoiceOver;
- 0.7.8 считает размер BrowserData, импортирует конфигурации и показывает
  proxy-check freshness вне ложного состояния «свежо»;
- atomic folder distribution для импорта;
- lifecycle health center: locks, recovery, BrowserData size, last launch;
- aggregate privacy panel без device IDs и raw values;
- proxy-route status без отображения реального IP;
- extension/download provenance и explicit quarantine;
- manager performance budgets и runtime provenance card;
- synthetic fingerprint corpus и isolation harness;
- redacted support bundle с независимым fail-closed verifier;
- signed/notarized/stapled artifacts, Gatekeeper, hosted ZIP/DMG и live
  download verification для последнего public release.

Следовательно, старый список из 30 пунктов больше не является актуальным
списком «всё сделать». Большая часть manager-пунктов закрыта. Реальные
оставшиеся задачи находятся в runtime evidence, update/rollback, background
request inventory, usability-polish и release automation.

## 3. Границы этого цикла

Входит:

- manager-only улучшения после 0.7.9 без изменения Chromium;
- перенос оставшихся тяжёлых profile-file операций с UI-потока;
- benchmark-first аудит поиска, папок, тегов и accessibility;
- исправление только доказанных пробелов, не добавляя лишних панели и настроек;
- тесты, version bump и Direct release gates, если exact candidate проходит
  все подтверждённые проверки.

Не входит в эту итерацию:

- пересборка, замена или портирование Chromium;
- JavaScript-инъекции fingerprint, random noise per call и подмена реальных
  device IDs;
- автоматизация действий на сторонних сайтах, RPA, CAPTCHA/ban/anti-fraud
  bypass, cloud/team sync и write API;
- покупка или скачивание реальных fingerprint-профилей пользователей;
- публикация с неполным source/runtime/signing/notarization evidence.

## 4. Исследовательские выводы

### 4.1 Chromium и web-platform

- Официальное Stable-объявление Chrome 154 от 22 сентября 2026 указывает
  154.0.8037.57/.58 для Windows/Mac и 108 security fixes. Встроенный runtime
  NeAntik 153.0.8010.52 отстаёт; этот manager-only срез не обновляет ядро.
  [Chrome Releases](https://chromereleases.googleblog.com/2026/09/stable-channel-update-for-desktop_0856730748.html).
- Storage partitioning применяется к storage, service workers и communication
  API в third-party contexts; профильный storage нужно тестировать не только
  на cookies, но и на IndexedDB, Cache Storage, service workers и Broadcast/
  SharedWorker-подобных каналах.
- Permissions Policy позволяет ограничивать geolocation, camera, microphone,
  Client Hints и другие мощные возможности для cross-origin frames. В продукте
  нужно показывать aggregate permission state и явное происхождение решения,
  не раскрывая сырые значения.
- W3C WebRTC прямо указывает, что ICE candidates, media capabilities и SDP
  увеличивают fingerprint surface; force-relay/ограниченная политика меняют
  сетевое поведение и должны быть измеряемыми, а не обещанными.
- User-Agent Client Hints — запрашиваемые и policy-controlled сигналы. Любое
  будущее изменение identity обязано связывать UA, Client Hints, platform,
  runtime major/minor и capability matrix.

### 4.2 Что реально делают конкуренты

Официальные материалы GoLogin, Multilogin, Kameleo, AdsPower, Incogniton и
MoreLogin повторяют устойчивый набор функций:

- отдельный профиль с cookies/storage/history/extensions;
- proxy + WebRTC/timezone/geolocation/language alignment;
- coherent fingerprint templates вместо независимой случайности;
- профили, папки, теги, notes, search, clone, import/export;
- fingerprint inspector/audit и proxy tester;
- cloud sync, team roles, API, automation и paid scale;
- иногда cloud browser, mobile emulation, Widevine и cookie collector.

Наш осознанный ответ — не копировать платный cloud/automation слой. Сильная
ниша NeAntik: бесплатный локальный open-source-friendly manager для Mac,
минимум настроек, понятный lifecycle, отсутствие обязательного аккаунта,
локальная изоляция и проверяемые defensive-аудиты. Это одновременно делает
продукт проще и уменьшает attack/privacy surface.

Ключевой вывод из документации Kameleo и Multilogin: правдоподобие ухудшается
при независимой случайности. Поэтому каталог identity должен развиваться
только целыми проверенными tuple-когортами и только после измерений; реальные
снятые fingerprints в репозиторий не добавляем.

## 5. Новая архитектура продукта

### Слой A — Workspace manager

- ProfileStore и organization sidecar — единственный источник metadata.
- Все операции import, clone, snapshot restore и folder assignment — атомарные.
- Публичные DTO allowlist-only; секреты и BrowserData физически исключены.
- Search/filter остаются быстрыми на 1/50/100 профилях.

### Слой B — Profile runtime contract

- BrowserData, cookies, storage, permissions, extensions, downloads и proxy
  state принадлежат profile ID.
- Launch допускается только после runtime preflight и свежей proxy preparation.
- A→B→A — только явный инженерный release action, никогда не background magic.
- Crash/recovery/lock states fail closed.

### Слой C — Defensive observation

- Synthetic fixtures и собственные test pages;
- bounded observation: verdict, categories, freshness и configuration revision;
- raw evidence owner-only, capped and never shown in normal UX;
- diagnostics explain evidence origin: configured, derived, observed,
  unavailable, unverified.

### Слой D — Distribution

- Source lock, runtime lock, code signature, notarization, stapling and
  Gatekeeper are separate gates;
- hosted archive bytes must equal verified local candidate;
- public release and website manifest must agree on version/build/hash;
- rollback archive retained before replacing a release.

## 6. Приоритетный backlog

Статусы: `done` — проверено; `next` — можно делать без Chromium rebuild;
`runtime-gate` — только с точным runtime evidence; `defer` — сознательно не
делаем в компактном Direct-продукте.

### P0 — безопасность, корректность и UX, которые нельзя откладывать

| ID | Работа | Статус | Критерий готовности |
|---|---|---|---|
| P0-01 | Единая карточка Diagnostics | done | Один aggregate status вместо дублирующих секций |
| P0-02 | Понятное следующее действие для attention/unavailable | done | UI объясняет, что сделать, без raw paths/PIDs |
| P0-03 | Crash-safe launch/recovery/locks | done | Неполный launch не выглядит успешным |
| P0-04 | Atomic import + folder assignment | done | Нет частичного смешанного состояния |
| P0-05 | Fresh proxy preparation | done | Старый route verdict не переиспользуется бессрочно |
| P0-06 | Quarantine/provenance | done | Неизвестный артефакт не активируется автоматически |
| P0-07 | Runtime preflight | done | Неподходящий runtime блокирует запуск |
| P0-08 | Public evidence binding | shipped for 0.7.5 | Hash/version/source/artifact связаны |
| P0-09 | Secret/history audit | done | Нет credential-like files/values в reachable history |
| P0-10 | Manager perf budgets | done | p50/p95 отдельно от Chromium metrics |
| P0-11 | Explicit keyboard actions | done | Keyboard shortcuts and Tab navigation remain; by owner request, SwiftUI content is hidden from the VoiceOver tree. Native macOS menus/titlebar/system alerts remain OS-controlled. |
| P0-12 | Release version floor | done | Новый manager build строго выше recorded public floor; проверено v0.7.11/74 |

### P1 — следующий функциональный слой без изменения ядра

| ID | Работа | Статус | Критерий готовности |
|---|---|---|---|
| P1-01 | Diagnostics next-step UX | done | Attention state даёт короткое действие |
| P1-02 | Proxy test result history summary | done in 0.7.8 | Только last state/freshness/verdict, без IP |
| P1-03 | Profile quick-start templates | shipped in 0.7.9 | 2–3 safe templates, только имя/тег; runtime defaults не меняются |
| P1-04 | Snapshot retention/restore clarity | done | Last 3, fresh identity, corruption gate |
| P1-05 | Read-only support bundle | done | Allowlist-only, <=64 KiB |
| P1-06 | Local diagnostics adapter design | defer | Только read-only, authenticated loopback |
| P1-07 | Signed runtime update + rollback | runtime-gate | Signed manifest, atomic swap, rollback proof |
| P1-08 | Chromium background-request inventory | runtime-gate | Exact runtime capture and policy decision |
| P1-09 | Runtime cold/warm/idle metrics | runtime-gate | Qualified producer + exact hash + GUI smoke |
| P1-10 | Site compatibility report | shipped in 0.7.9 | Показывает локальную доступность API; stale через 24 часа; не доказывает успех сайта |
| P1-11 | Profile integrity/recovery UX | done | Read-only notice remains visible in Diagnostics or at workspace level when no profile is selected; repair stays deferred |
| P1-12 | Release evidence dashboard | shipped in 0.7.9 | Read-only CLI summary; требует чистый источник и не подменяет свежие release gates |
| P1-13 | Snapshot restore preview | shipped in 0.7.10 | Safe aggregate summary before commit; cancel is mutation-free; transactional store checks remain authoritative |
| P1-14 | Restore preview spoken announcements and app VoiceOver tree | removed/hidden locally in `66c590b` and `b23b4b9` | Public 0.7.11 historically announced one aggregate summary. Local code removes app-issued announcements and hides main SwiftUI content, sheets, and popovers from the VoiceOver tree; keyboard actions remain. A limited focused smoke was recorded in an earlier Dev.app session, without an exact source binding; a later retry did not reach the UI, so repeat physical keyboard QA on a usable Dev.app and exact candidate. |

### P2 — зрелость продукта после P0/P1

| ID | Работа | Статус | Критерий готовности |
|---|---|---|---|
| P2-01 | Expand coherent Apple Silicon tuple catalog | runtime-gate | New cohort fixtures and compatibility matrix |
| P2-02 | Canvas/WebGL/Audio/Client Hints coherence | runtime-gate | Cross-surface observations agree |
| P2-03 | Media capability cohort audit | runtime-gate | No raw device IDs, only approved classes |
| P2-04 | WebRTC route policy matrix | runtime-gate | direct/proxied/relay cases measured |
| P2-05 | Download policy inventory | runtime-gate | Chromium requests classified before policy change |
| P2-06 | Visual responsive polish | done | Narrow-width view snapshots и flexible columns покрыты render tests |
| P2-07 | Onboarding first-run copy | done | Один основной create/open action, понятный retry и native control hints |
| P2-08 | Documentation/tutorials | shipped in 0.7.9 | Bilingual profile privacy, snapshot/restore and configuration-transfer guide |
| P2-09 | Reproducible manager build metadata | done in 0.7.8 | Candidate provenance и privacy verifier; нет build-machine paths |
| P2-10 | Fuzz malformed imports | done in 0.7.8 | Decoder fail-closed, bounded size/count, malformed corpus |
| P2-11 | Fuzz provenance/quarantine records | done in 0.7.8 | Unknown fields, symlink ancestor и path traversal отклоняются |
| P2-12 | Release rollback rehearsal | shipped in 0.7.9 | Retained ZIP/DMG v0.7.8 скопированы во временный staging и повторно сверены по байтам. Это не install/launch или hosted rollback smoke. |
| P2-13 | Distinguish BrowserData scan caps from filesystem errors | implemented/tested in `29b4325` | Entry/byte safety-cap hits have their own status; symlink and I/O failures remain unavailable |

### Defer permanently unless product direction changes

- cloud profile sync and team seats;
- RPA, bulk site actions, account farming or captcha/ban evasion;
- arbitrary JavaScript fingerprint injection and per-call noise;
- real-user fingerprint scraping or purchased fingerprint dumps;
- public write API, MCP/SDK launch endpoints;
- mandatory accounts, subscription gates or proxy marketplace;
- claims of anonymity, universal undetectability or guaranteed anti-fraud pass.

## 7. Доставленный срез: manager 0.7.6

Первый вертикальный срез этого цикла доставлен в Direct 0.7.6: Diagnostics
получил `next step`.

### Пользовательский результат

- `В порядке` остаётся спокойным и не занимает место;
- `Требует внимания` объясняет конкретное безопасное действие: дождаться
  освобождения, восстановить профиль, повторить проверку движка или открыть
  подробности;
- `Проверка недоступна` не маскируется под проблему конкретного профиля и
  предлагает повторную проверку/просмотр деталей;
- никаких реальных путей, IP, PID, device IDs или raw fingerprint values.

### Реализация

1. Расширить `ProfileDiagnosticsSummary` allowlisted enum `nextStep`.
2. Добавить компактную строку действия в `ProfileDiagnosticsSummaryView`.
3. Покрыть ready/attention/unavailable и accessibility presentation tests.
4. Не менять BrowserLaunchPolicy, runtime locator, Chromium resources или
   proxy/fingerprint semantics.
5. Поднять manager version/build только после прохождения полного test gate.

### Почему это первый срез

Он закрывает реальную UX-проблему, не увеличивает privacy surface, не требует
нового runtime и даёт измеримый результат. После него следующий безопасный
срез — короткий proxy-result summary и profile integrity repair assistant.

## 7.5 Manager-only срез 0.7.8 / build 71

Срез опубликован как v0.7.8 / build 71 через Direct Distribution; source и
артефакты привязаны к коммиту `a687702ed5d0176bb41126a2d4d6cf06f391e68f`.
ZIP/DMG прошли Developer ID, notarization, stapling и Gatekeeper; hosted ZIP
прошёл повторную проверку байтов, кандидата и evidence; опубликованный DMG
повторно скачан и совпал по SHA-256. Chromium не пересобирался.

- BrowserData обходится в отменяемой utility task. При смене выбранного
  профиля или состояния запуска предыдущий результат не может перезаписать
  текущий; до результата интерфейс показывает «Считаю размер…».
- Чтение, ограниченная проверка размера, JSON decode и расшифровка импорта
  выполняются вне main actor. Новые профили сохраняются существующей
  атомарной транзакцией ProfileStore.
- Сводка proxy показывает время проверки и различает свежий успех, устаревший
  результат, последний сбой, неизвестное время и смену конфигурации. IP,
  endpoint и raw error в проекцию не включены; сетевой тест сам не запускается.
- Карантин отклоняет файл, достигнутый через symlink-предок внутри BrowserData.
- Bounded corpus malformed imports расширен вариантами версии и формы JSON.

Chromium/runtime lock остаётся закреплён на 153.0.8010.52. Chrome Stable 154
вышел 22 сентября и содержит security fixes; manager-релизы 0.7.10 и 0.7.11
не закрывают эту разницу и не являются обновлением безопасности ядра.

## 8. Итог цикла 0.7.11 и gates следующего релиза

### Фаза 0 — release baseline (24 сентября 2026)

- исторический локальный release record: v0.7.11 / build 74, Chromium
  153.0.8010.52; GitHub Release API metadata и asset digests свежо совпали
  с записанными version/build/hash; сами bytes в этом pass не скачивались;
- binary source commit: `fa3b03cbe122840ea308d2ecf19004a1128a1a06`;
- recorded ZIP SHA-256:
  `141ffacec0fb601a9e20fa722b348bc6eed444132efee9c72ab582b5645d3576`;
- recorded DMG SHA-256:
  `fa0489a57b790f51f3d8eea0fa2b4d816bf9a123559f9fd0da71e0ddab6521f4`;
- при публикации запись указывала browser.free Sites version 92, API тогда
  отвечал `canDownload=true`, а remote tag указывал на source commit; это
  исторический ответ, позже заменённый после обновления security baseline;
- последняя записанная browser.free Sites version 95 показывает историю
  0.7.11, а сохранённый API ответ — `published-runtime-gated`,
  `canDownload=false` и `downloadUrl=null`; текущая live-проверка не прошла по
  DNS/network и требует повторения;
- GitHub API по-прежнему показывает v0.7.10 как опубликованный rollback release;
- release record и notary history подтверждают принятые ZIP/DMG submissions;
  этот аудит не скачивал заново payload и не повторял Gatekeeper на свежих
  байтах.

24 сентября Chrome Stable 154 для Mac выпущен как `154.0.8037.58` с 108
security fixes. Обновлённый manual security baseline поэтому блокирует
Chromium `153.0.8010.52`; новую Direct-бинарную версию нельзя выпускать без
полного runtime gate cycle. Пользователь разрешил update/release; gates пока
не пройдены.

### Фаза 1 — manager-only vertical slice

Большая часть lifecycle, background file work, metadata-only transfer,
privacy-safe status и release evidence summary вошла в 0.7.9. Релиз 0.7.10
добавляет preview snapshot до commit: он использует тот же заранее
проверенный payload, показывает только дату и aggregate counts,
не меняет store при отмене и повторно проверяет работающие профили при commit.
Публичный 0.7.11 исторически включал app-issued речевые объявления для preview
восстановления. Локальный commit `66c590b` удаляет их; `b23b4b9` скрывает
SwiftUI-интерфейс приложения из VoiceOver tree по запросу владельца. Tab и
горячие клавиши сохранены; нативные меню и системные alerts остаются под
управлением macOS. Изменение ещё не попало в новый бинарный Direct-релиз.

Полный локальный набор прошёл: 636 Swift-тестов и 689 Python-тестов (один
skip); loopback-тест потребовал разрешённого macOS-контекста после sandbox
`EPERM`. Ограниченный keyboard smoke был записан в более ранней Dev.app-сессии,
но не привязан к source hash. При повторной попытке открыть Dev.app UI не
появился из-за предупреждения о неверном формате Development-данных; данные
оставлены без изменений. Точный candidate ещё отсутствует и физически не
проверен, поэтому keyboard smoke следует повторить на usable Dev.app и exact
candidate; системный VoiceOver не запускался.
Release preflight теперь выбирает source contract по major-версии runtime lock,
но текущему runtime 153 требуется отсутствующий контракт 153; security
baseline 154 остаётся независимым обязательным gate.

### Фаза 2 — критерии следующего exact manager candidate

- следующая версия/build должна быть выше v0.7.11/74 и пройти полный набор
  source, manager и privacy checks;
- собрать manager-only Direct candidate с тем же exact Chromium/runtime;
- связать candidate manifest, source commit, runtime hashes и UI evidence;
- не считать Swift test build локальным release artifact.

### Фаза 3 — повторяемые gates будущей публикации

- Developer ID, Apple notarization, stapling и Gatekeeper;
- заново скачать ZIP и DMG и сверить точные SHA-256;
- обновить GitHub Release и browser.free contract/page только для exact
  проверенного candidate;
- проверить production deployment и публичный `/api/release` contract;
- сохранить v0.7.10 как rollback release; не удалять предыдущие версии.

## 9. Release acceptance gates

Публикация разрешена только если все пункты подтверждены свежими отчётами:

1. exact source commit and clean intended diff;
2. manager version/build greater than the recorded v0.7.11/74 baseline;
3. runtime version/hash remains exactly pinned and unchanged;
4. package contains no secrets or local source paths;
5. Swift tests and targeted tests pass;
6. profile isolation and malformed-import tests pass;
7. runtime signature, architecture, preflight and baseline pass;
8. Developer ID, notarization, stapling and Gatekeeper pass;
9. archive SHA-256 equals the hosted artifact;
10. public page/API/release all report the same version/build/hash;
11. a clean-machine or fresh-download smoke can launch and create a profile;
12. previous public artifact remains available for rollback.

Последняя записанная read-only GitHub API проверка подтвердила неизменяемый
опубликованный v0.7.11 и asset metadata: ZIP SHA-256
`141ffacec0fb601a9e20fa722b348bc6eed444132efee9c72ab582b5645d3576`, DMG
SHA-256 `fa0489a57b790f51f3d8eea0fa2b4d816bf9a123559f9fd0da71e0ddab6521f4`;
v0.7.10 rollback release и его assets были перечислены. В этом pass артефакты
заново не скачивались, поэтому свежая подпись и Gatekeeper на байтах не
подтверждались. Последняя записанная проверка browser.free Sites version 95 и
live `/api/release` показывала `published-runtime-gated`, `canDownload=false`,
`downloadUrl=null`; повторная проверка сейчас не удалась из-за DNS/network, а
GitHub CLI сообщает о недействительных настроенных токенах. Поэтому live
публичное состояние пока не подтверждено заново. Обязательный NeAntik `doctor`
ранее останавливался на deploy credential; это отдельный deploy-path gate.
Для точного официального M154 `.58` выполнен только disposable diagnostic
build: GN сгенерировал 35,105 targets, compile остановился на 11,815/14,159 из-за
удалённого patchset’ом Safe Browsing renderer API. Автоматическая проверка
отклонила попытку убрать hook как ослабление защиты; policy-вопрос не решён,
runtime candidate отсутствует. Новый exact candidate и его физический keyboard smoke ещё не существуют;
strict production fingerprint coherence не подтверждена. Ограниченный набор
клавиатурных сценариев записан в ранней Dev.app-сессии без exact source
binding; более поздний повторный запуск не дошёл до UI из-за Development-data
warning. Повторить физическую проверку нужно на пригодном Dev.app и exact
candidate. Системный VoiceOver не запускался. SwiftUI-контент приложения
скрывается из его accessibility tree по решению владельца, тогда как нативные
меню macOS и system alerts остаются под управлением ОС.

## 10. Источники нового исследования

- Chromium/Chrome stable release: https://chromereleases.googleblog.com/2026/09/stable-channel-update-for-desktop_0541751186.html
- Chrome 154 macOS Stable and security fixes (22 September 2026): https://chromereleases.googleblog.com/2026/09/stable-channel-update-for-desktop_0856730748.html
- Chrome 153 release notes: https://developer.chrome.com/release-notes/153
- Chrome storage and cookie partitioning: https://developer.chrome.com/docs/extensions/develop/concepts/storage-and-cookies
- Chrome Permissions Policy: https://developer.chrome.com/docs/privacy-security/permissions-policy
- Chrome User-Agent Client Hints: https://developer.chrome.com/docs/privacy-security/user-agent-client-hints
- W3C WebRTC Recommendation: https://www.w3.org/TR/webrtc/
- W3C IP privacy notes: https://www.w3.org/wiki/Privacy/IPAddresses
- Kameleo fingerprint consistency: https://developer.kameleo.io/concepts/fingerprints/
- Kameleo fingerprint inspector: https://developer.kameleo.io/tutorials/using-fingerprint-inspector/
- Multilogin fingerprint settings: https://www.multilogin.org/help/en_US/browser-profile-setup/profile-settings-fingerprint-section
- AdsPower fingerprint documentation: https://help.adspower.com/docs/browser_fingerprint
- GoLogin profile model: https://support.gologin.com/en/articles/14853788-what-is-a-browser-profile
- Incogniton developer/API model: https://api-docs.incogniton.com/getting-started/introduction
- MoreLogin browser profile API model: https://guide.morelogin.com/api-reference/browser

## 11. Definition of done текущего manager-only goal

- roadmap отражает исходную точку 0.7.11 и следующие неготовые пункты;
- snapshot save/restore и plain/encrypted export не сериализуют большие
  документы на UI-потоке;
- повторное изменение состояния профилей не может привести к частичному
  восстановлению или записи;
- восстановление profiles/folders остаётся read-only evidence в Diagnostics;
  повреждённый JSON, пути и BrowserData не показываются и не меняются;
- search/folder/tag performance измерены, существующая семантика сохранена;
- targeted tests, accessibility/render checks и полный Swift gate проходят;
- runtime Chromium и fingerprint/network semantics не изменены;
- новая версия опубликована после всех Direct gates, либо кандидат остановлен
  на конкретном непрохождении gate без ложного объявления релиза;
- handoff содержит source commit, version/build, тесты, SHA-256, live checks,
  rollback и оставшиеся runtime-gate пункты.

## Историческая сверка — 29 сентября 2026 (заменена статусом ниже)

Исторические значения Sites version 92/95 и недоступности browser.free,
записанные выше, superseded: Sites сейчас version 98, а свежий
`browser.free/api/release` отвечает и подтверждает прежний опубликованный
0.7.11/build 74 с Chromium 153 и `canDownload=false`. GitHub connector доступен
для чтения; сохранённые локальные GitHub CLI-токены сейчас недействительны,
поэтому asset upload этим CLI не авторизован. Сертификаты Developer ID и
`neantik-notary` доступны в разрешённом macOS-контексте. Chrome M154 `.58`
остаётся последним broad Stable для Mac; M155 пока Early Stable для малого
процента. M154 port diagnostic-only, без проверенного macOS source pair,
hermetic SDK/toolchain и source contract. Без этих inputs Chromium build,
integrated candidate и публикация не готовы; v0.7.11 остаётся rollback.

## Состояние выпуска — 2 октября 2026

GitHub CLI снова доступен: свежий запрос latest release подтвердил `v0.7.11`
с ZIP/DMG и контрольными суммами; повторная авторизация не требуется.
Chromium `154.0.8037.93` собран, происхождение исходников и проверка
подписанного Developer ID runtime пройдены. Кандидат менеджера — `0.7.12`
build `75`. Интегрированное приложение собрано; продолжаются его проверки,
затем требуются свежий authenticated GUI A → B → A, нотариальное заверение
ZIP/DMG и проверка опубликованных файлов. Новый релиз ещё не опубликован,
сайт ещё не переведён на него. `v0.7.11` сохраняется для отката.
