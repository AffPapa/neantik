# NeAntik — глобальный план продукта и следующего цикла

Дата ревизии: 24 сентября 2026 года.

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

Публичный baseline перед этой итерацией:

- NeAntik 0.7.5, build 68;
- Direct Distribution для Apple Silicon;
- встроенный Chromium 153.0.8010.52 ARM64 Metal;
- локальные профили, папки, поиск, теги, snapshots, безопасное копирование;
- metadata-only import/export через системные диалоги;
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

- новый большой план и явная матрица статусов;
- manager-only улучшения, не требующие пересборки Chromium;
- единая модель понятного следующего действия в диагностике профиля;
- тесты, release notes, version bump и полный release gate при наличии всех
  подтверждённых артефактов;
- повторная проверка секретов/лишних файлов в Git history перед публикацией.

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

- Актуальные Chrome 153 release notes фиксируют изменения Privacy Sandbox и
  удаления ряда API; нельзя навечно зашивать старую карту возможностей и
  выдавать её за стабильный контракт.
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
| P0-11 | Accessible primary actions | done | Keyboard/VoiceOver labels and hints |
| P0-12 | Release version floor | next | Новый manager build строго выше public floor |

### P1 — следующий функциональный слой без изменения ядра

| ID | Работа | Статус | Критерий готовности |
|---|---|---|---|
| P1-01 | Diagnostics next-step UX | done | Attention state даёт короткое действие |
| P1-02 | Proxy test result history summary | next | Только last state/freshness/verdict, без IP |
| P1-03 | Profile quick-start templates | next | 2–3 safe templates, никаких самолётных настроек |
| P1-04 | Snapshot retention/restore clarity | done | Last 3, fresh identity, corruption gate |
| P1-05 | Read-only support bundle | done | Allowlist-only, <=64 KiB |
| P1-06 | Local diagnostics adapter design | defer | Только read-only, authenticated loopback |
| P1-07 | Signed runtime update + rollback | runtime-gate | Signed manifest, atomic swap, rollback proof |
| P1-08 | Chromium background-request inventory | runtime-gate | Exact runtime capture and policy decision |
| P1-09 | Runtime cold/warm/idle metrics | runtime-gate | Qualified producer + exact hash + GUI smoke |
| P1-10 | Site compatibility report | next | User sees compatibility category, not spoof raw values |
| P1-11 | Profile integrity repair assistant | next | Explicit repair actions, backup first, no silent mutation |
| P1-12 | Release evidence dashboard | next | Read-only local summary of gate state |

### P2 — зрелость продукта после P0/P1

| ID | Работа | Статус | Критерий готовности |
|---|---|---|---|
| P2-01 | Expand coherent Apple Silicon tuple catalog | runtime-gate | New cohort fixtures and compatibility matrix |
| P2-02 | Canvas/WebGL/Audio/Client Hints coherence | runtime-gate | Cross-surface observations agree |
| P2-03 | Media capability cohort audit | runtime-gate | No raw device IDs, only approved classes |
| P2-04 | WebRTC route policy matrix | runtime-gate | direct/proxied/relay cases measured |
| P2-05 | Download policy inventory | runtime-gate | Chromium requests classified before policy change |
| P2-06 | Visual responsive polish | next | Detail/sidebar remain usable at narrow widths |
| P2-07 | Onboarding first-run copy | next | One primary action and no technical noise |
| P2-08 | Documentation/tutorials | next | Local-first profiles, privacy and recovery explained |
| P2-09 | Reproducible manager build metadata | next | No local absolute source paths in binary |
| P2-10 | Fuzz malformed imports | next | Decoder fail-closed, bounded CPU/memory |
| P2-11 | Fuzz provenance/quarantine records | next | Unknown fields and path traversal rejected |
| P2-12 | Release rollback rehearsal | next | Public candidate can be restored from retained bytes |

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

## 8. План выполнения по фазам

### Фаза 0 — контроль исходной точки

- проверить branch/status/HEAD;
- проверить version/build/runtime lock;
- проверить reachable Git history на секреты и лишние release artifacts;
- зафиксировать текущие test counts и baseline.

### Фаза 1 — новая функция

- реализовать P1-01;
- добавить unit tests и UI/presentation tests;
- обновить ROADMAP и CHANGELOG;
- прогнать Swift test suite, lint/build и targeted verifiers.

### Фаза 2 — release candidate

- поднять только manager version/build — выполнено для 0.7.6/69;
- собрать Direct candidate на существующем Chromium;
- повторить source binding, runtime integrity, privacy, isolation и manager
  checks;
- не считать локальный unsigned build публичным релизом.

### Фаза 3 — публикация, только если gates зелёные

- Developer ID signing;
- Apple notarization через Keychain profile;
- stapling;
- Gatekeeper;
- ZIP/DMG byte/hash verification;
- GitHub Release;
- browser.free manifest/page update;
- fresh hosted ZIP/DMG download and live smoke;
- сохранить current/previous rollback artifacts.

## 9. Release acceptance gates

Публикация разрешена только если все пункты подтверждены свежими отчётами:

1. exact source commit and clean intended diff;
2. manager version/build greater than public 0.7.5/68;
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

Если хотя бы один пункт не подтверждён, остаёмся на source/test candidate и
не называем его новой публичной версией.

## 10. Источники нового исследования

- Chromium/Chrome stable release: https://chromereleases.googleblog.com/2026/09/stable-channel-update-for-desktop_0541751186.html
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

## 11. Definition of done для этого goal

- этот документ добавлен в Git и отражает реальное состояние, а не старый
  список;
- P1-01 реализован без Chromium rebuild;
- targeted tests и полный Swift gate пройдены;
- новая версия либо опубликована после всех release gates, либо честно
  остановлена на конкретном доказуемом внешнем gate с сохранённым candidate;
- в handoff перечислены commit, version/build, тесты, артефакты, live-check и
  оставшиеся runtime-gate пункты.
