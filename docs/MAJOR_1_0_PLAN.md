# NeAntik: план до версии 1.0

**Доставлено 16 октября:** [0.8.20 (132)](../releases/v0.8.20.json) опубликована с восемью полными upstream security backports; source review связывает десять fixes с точным contract. Кандидат131 удержан и не опубликован. [Доказательства и границы](security/runtime-security-2026-10-16.md). Ранее пройденные проверки без изменения входов не повторяются.

Последний квалифицированный GitHub-выпуск — [0.8.22 (134)](../releases/v0.8.22.json): принятое завершение Chromium показывает «Закрывается…» в UI и MCP; точный app, публичные ZIP/DMG и скачанный MCP проверены. Runtime и данные профилей сохранены из133. Установка — вручную через подписанный DMG/ZIP; установленный updater этим выпуском не квалифицирован. browser.free остаётся на0.8.16: Sites-публикация заблокирована автоматической проверкой передачи credential. Полная приёмка1.0остаётся открытой. Точная очередь — в [NEXT_1_0_SLICES](NEXT_1_0_SLICES.md); исторические проверки повторяются только при изменении входов или конкретном оставшемся риске.

В128 опубликованы удаление WebKit и recovery с точной signed/hosted квалификацией. В127 ранее опубликован recovery pin, завершён signed WebKit startPage-контроль, выполнен controlled DNS raw-runtime срез. Дополнительно на скачанных128 и130 (каждая со своими runtime/manager hashes) подтверждён manager/relay upstream DNS с отказом и восстановлением; глобальный DNS/UDP, фоновые запросы и смена сети остаются открытыми. В129 опубликован GUI-MCP для своих окон с явным разрешением; WebKit proxy/media/backup не объявляются готовыми. [Приоритеты следующих срезов](NEXT_1_0_SLICES.md) отделяют эти задачи от уже пройденного. Исследование Fury сохранено; код его AGPL-компонентов в продукт не копируется.

## Очередь работ

1. **Быстрее разрабатывать.** Общие кэши, четыре CI-сегмента, точечный выбор тестов, защита от параллельной записи в кэш и компактные правила. Локальная проверка инструментов выполнена; CloudCI301 выполнен; очередь macOS ARM и cold build учтены отдельно.
2. **Вкладки WebKit.** Новая вкладка, переключение, закрытие и ссылки, открывающие новое окно. Все вкладки одного профиля используют его хранилище. Данные разных профилей разделены. Опубликовано в0.8.3: exact signed WebKit A/B full restart, public bytes и downloaded launch проверены.
3. **Сеть и удобства WebKit.** Загрузки опубликованы в0.8.6, опциональное восстановление вкладок после штатного выхода — в0.8.7 (exact signed/hosted/headed/MCP проверены). Кэш закрытого WebKit-профиля опубликован в0.8.8: native/exact A/B, cookies/LS/IDB/SW/CacheStorage/session сохранены. Публичный SDK proxyConfigurations сам по себе не подтверждает DNS/WebRTC UDP; refusal остаётся. Прокси требуют отдельной revocable authority, DNS/WebRTC/no-Direct проверки; до них proxy launch запрещён. GUI-MCP опубликован в129 в ограниченном scope; полный backup остаётся открытым.
4. **Обязательные проверки 1.0.** Закрыть оставшиеся P0 из таблицы ниже, затем проверить данные, совместимость и обновление между актуальными выпусками.
5. **Дополнительные функции.** WireGuard и командная работа отложены по [исследовательскому решению и условиям возврата](OPTIONAL_NETWORK_TEAM_DECISIONS.md). Это не реализованные функции. Финальная 1.0 выпускается только после обязательной квалификации.

Для продуктового среза: изменение → профильные тесты → реальные операции в браузере → подписанный кандидат → нотарификация и Gatekeeper → GitHub и сайт → проверка скачанных файлов. Инструменты разработки и документация проходят свои профильные проверки; новый бинарный выпуск для них не требуется. Пройденную проверку повторяем при изменении её входных данных, ошибке или конкретном оставшемся риске.

## Разрабатывается: доступ к камере и микрофону WebKit

Добавлены настройка ask/deny для остановленного профиля, перенос через копию/шаблон/экспорт/MCP и формат3 для запрета. Настройка с запретом не читается старыми версиями вместо её игнорирования. Локальные проверки модели, прав владения, настоящих WKFrameInfo и формы Dev прошли. Камера и микрофон не использовались; getUserMedia, прежнее разрешение сайта, системный отказ/отзыв и точная подписанная поставка ещё не проверены. Это development-срез, в0.8.8 его нет.

Добавлены purpose strings и точные camera/audio-input claims в подготовку новой подписи и validator нового updater. Выпущенный0.8.8 сохраняет прежний validator и откажет кандидату с дополнительными правами. Требуется проверенный переход; исправление нового validator само по себе не доказывает обновление старой версии. Первый переход0.8.8→0.8.10 теперь проверен настоящими install/ACK/relaunch и rollback; опубликованы legacy и v2 feeds. Media остаётся отключена. Включение и следующий переход требуют реального capture, отказа/отзыва и отдельного exact candidate gate.

## Проверки Chromium 0.8.3

18 headed проверок прошли на точных подписанных байтах опубликованного runtime. Использованы временные профили и mock Keychain. В тесте OOPIF добавлены готовность документа и два кадра перед измерением: нулевые размеры по-прежнему считаются ошибкой. Контроль обычного Chrome 155.0.8059.40 привязан к версиям, хешам и исходникам; отсутствующий HTTP-заголовок должен быть записан явно, а не пропущен в отчёте.

[Машиночитаемые результаты и границы проверки](evidence/platform-0.8.3.json). Это проверка runtime с конфигурацией, экспортированной менеджером; полный путь GUI, сеть и все требования 1.0 проверяются отдельно.


## Дополнительно проверено: Canvas в 0.8.11

Закрыт пробел в проверках копирования, дробной прозрачности и `reset()`: точный подписанный M156, тот же движок без настройки профиля и отдельно загруженный официальный Chrome 155.0.8059.80 прошли численные проверки. Два реально запущенных сломанных варианта — замена `copy` на `source-over` и сохранение bitmap после `reset` — отклонены. Первоначальные два нечувствительных теста исправлены; старые результаты этого среза сохранены. [Хеши, результаты и ограничения](evidence/canvas-operations-0.8.11.json). Байты приложения не менялись; это усиление квалификации, а не новый бинарный выпуск.

## Конечная приёмка без повторных кругов

Исходные операции отделены от дополнительного покрытия. Доказанные Canvas/WebGL/Audio/контексты не становятся незавершёнными из-за требования проверить все возможные размеры, API или Mac. Конечные остатки1–18: font/cohort mapping и миграции, privacy-safe locale/events голосов, actual codecs/PDF/storage. HTTPS/cross-origin identity подтверждена на точном runtime129 в отдельном bounded срезе. Физический дисплей, питание, смена сети и capture отмечаются отдельно. Равенство executable/framework128/129 с runtime0.8.3 подтверждено в текущем checkpoint; изменённые manager/config пути остаются отдельными gates.

## Все 45 пунктов

|№|Приоритет|Задача|Фактическое состояние|Следующее доказательство|
|---|---|---|---|---|
|1|P0|Шрифты|Подписанный M156: DOM/Canvas, fonts.ready, fallback/absent/load и повторы подтверждены|CoreText primitive/draw/collision/fallback проверены локально;13-file patch прошёл GN и7-object compilation ([scope](evidence/font-policy-chromium-objects.json)). Runtime и renderer witness проверены в bounded research scope; [девять шрифтовых контекстов](evidence/font-nine-context-development.json) прошли на отдельном подписанном successor. [Font Access](evidence/font-access-development.json) с permission/blob/standalone-origin controls проверен на том же research runtime; [Skia collection/style/реальные variable clones](evidence/font-skia-development.json) проверены нативной пробой; исправлен ложный отказ variation source. [Новый шестислойный signed headed runtime](evidence/font-variation-headed-development.json) прошёл относящиеся к изменению font9/FontAccess gates. [Manager opt-in, UI/MCP и native lifecycle проверены локально](evidence/font-manager-activation-development.json); Exact signed/headed/hosted кандидат опубликован в [0.8.18](../releases/v0.8.18.json); другие OS/cohort и extended TextMetrics остаются дополнительным покрытием.|
|2|P0|Девять контекстов|Подписанный M156: девять контекстов, операции и lifecycle подтверждены|Сохранить evidence по доступным API. Отсутствие каждого API в каждом realm не является пробелом исходной задачи.|
|3|P0|Canvas чтения|Подписанный M156: все перечисленные raw/PNG/blob/Offscreen/crop пути и повторы подтверждены|Нет конкретного открытого пробела исходных read paths. Новые размеры/ICC/форматы — отдельное расширение, без повторения общего suite.|
|4|P0|Canvas инварианты|Точный M156: исходные Canvas инварианты, copy/alpha/reset и реальные сломанные контроли подтверждены|Сохранить evidence0.8.11; дополнительные ICC/форматы не удерживают исходный пункт открытым.|
|5|P0|WebGL1/2|Подписанный M156: WebGL1/2 операции, ошибки и context restore подтверждены|Конечный срез: renderer/CPU/screen/OS и реально доступные limits четырёх выдаваемых когорт; совместно с16.|
|6|P0|Audio|Подписанный M156: silence/DC/channels/analyser/offline/worklet и ошибки подтверждены|Физический capture относится к15; дополнительные MessagePort исключения не расширяют обязательный scope6.|
|7|P0|HTTP/JS identity|Проверено на точном runtime129: HTTPS, Accept-CH/delegation, same/cross redirects, DedicatedWorker и SW; fresh Chrome и unconfigured controls|[396проверок,8negative controls и границы](evidence/https-identity-0.8.17.json). Actual wire language contradiction и Direct control чувствительны; TLS peer→CONNECT→kernel custody. Не является production manager/relay, global DNS или OS-default HTTPS-upstream qualification. Старые HTTP fixtures не повторялись.|
|8|P0|Screen/geometry|Подписанный M156: headed screen/DPR/CSS/resize/zoom/fullscreen подтверждены|Второй физический дисплей — отдельное внешнее условие; не неопределённая матрица всех Mac.|
|9|P1|ClientRects|Подписанный M156: DOMRect/Range/scroll/text/transform/zoom и повторы подтверждены|Сохранить текущие инварианты; повтор на каждой когорте нужен только при изменении соответствующей политики.|
|10|P1|WebGPU|Подписанный M156: disabled policy и реальный unconfigured compute/readback подтверждены|WebGPU остаётся отключённым по решению. Включение необязательно и требует согласования capabilities перед отдельным выпуском.|
|11|P1|NetworkInformation|Подписанный M156: значения и listener API подтверждены|Реальное событие смены сети — конкретное оставшееся условие, когда доступно безопасное изменение среды.|
|12|P1|Battery|Подписанный M156: значения и listener API подтверждены|Реальное событие изменения питания — конкретное внешнее условие; не генерировать фиксированные данные.|
|13|P1|Память|Подписанный M156: JS/HTTP DeviceMemory, heap/quota и storage операции подтверждены|Сохранить различие RAM/heap/quota; другие устройства — дополнительная совместимость, без повторения текущих проверок.|
|14|P1|Speech voices|Четыре locale/events наблюдения прошли на точном downloaded134; полная приёмка открыта|[Стенд и evidence](SPEECH_OBSERVATION.md): configured en→fr→en + unconfigured fr, default/types, trusted initial delivery, synthetic negative, repeat и cleanup. Первый normal PASS не повторён; остальные3 по явному warning exception. Catalog change, WebKit и manager locale plumbing открыты.|
|15|P1|Media/permissions|Подписанный M156: synthetic media processing, permissions/revoke/deny и cleanup подтверждены|Физические camera/microphone и системный отказ/отзыв остаются внешней квалификацией; synthetic pipeline не повторять.|
|16|P1|Apple аппаратные когорты|Все11tuple прошли headed CPU/memory/screen/DPR/platform/GPU/repeat projection на runtime128;15persisted migration/edit/collision строк и4negatives прошли локально|[Конечная матрица и границы](evidence/cohorts-0.8.16.json).4issued входят в11tuple; полные API operations сохраняются в scope прежних matching receipts. Другие ОС/оборудование отдельно.|
|17|P1|Общие fingerprint когорты|Общая аппаратная когорта отделена от seed; конечная приёмка открыта|Два seed одной когорты, изоляция данных и A→B→A; не приравнивать уникальный fingerprint к анонимности.|
|18|P1|Обычная web совместимость|На точном опубликованном132 проверены6codec formats: decode/play/time/frames/tone, MediaCapabilities и native PDF; configured/unconfigured controls|[61семантическая проверка на сессию,10offline negatives, реальные corrupt-media/blank-PDF/invalid-config controls](evidence/compatibility-0.8.20.json). Начальный ICC falseFAIL исправлен offline по сохранённым PNG, без повторного configured запуска. Storage/download receipts сохраняют исходные привязки; DRM/MSE/другиеcodec profiles/OS отдельно.|
|19|P0|Маршрут Chromium|На скачанной130 с новым runtime подтверждены manager/relay upstream DNS и custody runtime/profile/revision/configuration;128 сохранена как отдельное историческое измерение; на129 отдельно raw-runtime HTTPS identity/CONNECT custody|[Manager scope130](evidence/manager-dns-0.8.18.json), [HTTPS scope](evidence/https-identity-0.8.17.json). Глобальные DNS/UDP, background, network change и отдельные production relay пути остаются открытыми. Уже пройденные raw/manager DNS и HTTPS identity без изменения входов не повторять.|
|20|P0|Отказ mid-session|Сохранены прежние channel-cut controls; на manager128 прошли SERVFAIL, отсутствие protected origin, Direct sensitivity и same-session recovery|Смена сети и глобальные пути остаются открытыми. Коррекция двух предположений harness выполнена offline по неизменённым receipts, не новым запуском.|
|21|P0|WebRTC negatives|[11 headed-контролей](evidence/webrtc-boundaries-0.8.21.json) и [реальный manager/relay:0→1→0](evidence/manager-webrtc-0.8.21.json) на133 прошли в указанном scope; приёмка полного пункта открыта|OS-managed policy, IPv6/TURN и внешние интерфейсы. Локальный тестовый policy provider не является проверкой системного управления; отказы дополнительных HTTP-соединений сохранены как неразобранная диагностика.|
|22|P0|Фоновые запросы|Ограниченные startup/idle/download/failure наблюдения сохранены; component completion исправлен и опубликован в133; полный пункт открыт|[Сетевое evidence130](evidence/background-network-0.8.18.json) и [поставленный successor fix133](../releases/v0.8.21.json): source/C++/headed controls callback/queue прошли. Это не общий telemetry/DNS/UDP PASS; OS-managed policies, другие среды и смена сети открыты.|
|23|P1|Per-profile relay|Chromium опубликован с ограничениями; WebKit production proxy остаётся отключён|HTTP/SOCKSauth relay and cleanup; HTTPSdefault-system-trust positive deferred. [DEBUG WebKit foundation и реальный loopback bypass](WEBKIT_PROXY_QUALIFICATION.md): отрицательный контроль выявил Direct arrival, native gate не пройден.|
|24|P1|Поэтапная proxy диагностика|опубликовано; полная матрица открыта|Stage-specific diagnostics exist; cross-enginefailure taxonomy to reconcile|
|25|P1|Явное определение протокола|Опубликовано в0.8.23/135; source/Dev/exact signed/hosted scope проверен|Отдельная кнопка без credentials, SOCKS5 greeting/HTTP407, явное применение; реальные socket controls включают HTTP200 negative, fragmentation, cancellation и закрытие peer до fixture cleanup. HTTPS и неоднозначный HTTP вручную. [Контракт](PROXY_PROTOCOL_DISCOVERY.md), [точный кандидат](evidence/proxy-protocol-discovery-0.8.23.json).|
|26|P1|Свой endpoint|опубликовано; endpoint-specific route scope|Custompreflight and signed browser endpoints; privacy/DNS limits preserved|
|27|P1|Активный network status|реализовано; lifetime matrix открыта|Revision/session observation implemented; continuous/allprotocol freshness acceptance open|
|28|P2|Domain allow/block|Не реализовано; сетевой scope и дизайн открыты|Текущие proxy bypass/DNS flags и WebKit URL-scheme policy не являются доменным firewall. Нет profile/MCP policy или matcher/fixtures. Требуются сетевые controls для subdomains, redirects, workers, WebSocket, DNS, cache и существующих соединений; отдельный navigation-only фильтр полный пункт не закрывает.|
|29|P2|WireGuard/profile|исследование завершено с обоснованным решением|WireGuard deferred by justified infrastructure/product design gates|
|30|P1|Full encrypted backup|опубликовано с ограничениями|Real signedQA restore cookies/LS/IDB/tabs and interruption; sameMac/Keychain only. В127 опубликован profile/journal recovery pin с реальными файловыми negative controls и безопасной формой; WebKit snapshot остаётся открыт.|
|31|P1|Clone vs restore|реализовано и проверено локально|Clone newidentity vsrestore original; noCrossMacsecret portability|
|32|P1|Cachecleanup|опубликовано publicalpha|Chromium safe cacheallowlist сохранён; WebKit HTTPdisk/memory cache0.8.8: native/exact A v2/Bv1, cookies/LS/IDB/SW/CacheStorage/session сохранены. Без размера/CodeCache/private paths; major hardware/OS coverage открыта.|
|33|P1|Extension center|опубликовано с ограничениями|Extension inventory/provenance+ownCRX native lifecycle; notuniversalinstallation|
|34|P1|CRX provenance|реализовано и проверено локально/на runtime|Full CRX3crypto checks and ownnative lifecycle; canceldialog unobserved|
|35|P1|Импорт|реализовано; ограниченная квалификация|Owned bookmarks import; noencryptedsecret import promise|
|36|P1|Graceful data close|проверено в ограниченном scope|Owned signed runtime/backup/updater durability; broader crash/timeout matrix open|
|37|P1|Проверенный updater|опубликовано с ограничениями|Exact signed088→0810 install/ACK/relaunch + preACKrollback; metadata2profiles unchanged; feeds live. В130 новый compiled record и actual QA ACK/preACKrollback прошли;129→130 только manual, production next-hop открыт. Futuremedia/multihop/data/OS gates open|
|38|P2|Bounded MCP observation|частично опубликовано|18management/7read tools; GUI IPC lifecycle опубликован в129 с connection/profile consent и exact signed controls. Page observation и realAIclient gates open; не выдавать lifecycle за чтение страниц.|
|39|P2|Self-hosted team|исследование завершено с обоснованным решением|No teaminfra productdecision; noimplementationclaim|
|40|P0|One vector patch+test|Исследование и локальная реализация; приёмка 1.0 открыта|Уточнить покрытие по сохранённым отчётам; выполнить недостающие проверки поведения на финальном кандидате. Исследование не закрывает приёмку.|
|41|P0|Positive/negative controls|Исследование и локальная реализация; приёмка 1.0 открыта|Уточнить покрытие по сохранённым отчётам; выполнить недостающие проверки поведения на финальном кандидате. Исследование не закрывает приёмку.|
|42|P0|Values vs behavior|Исследование и локальная реализация; приёмка 1.0 открыта|Уточнить покрытие по сохранённым отчётам; выполнить недостающие проверки поведения на финальном кандидате. Исследование не закрывает приёмку.|
|43|P0|Exact shipped browser|0.8.20(132) опубликована на GitHub public alpha; major1.0 открыта|[Точная подпись/Apple ZIP+DMG/Gatekeeper/hosted/headed/fontPolicy MCP](../releases/v0.8.20.json). Site остаётся153/128 из-за отдельной внешней блокировки. Прежние observations сохраняют исходные runtime/source привязки; номер версии не закрывает другие gates.|
|44|P1|Version regressionreport|реализован отчётный инструмент; поведенческая приёмка открыта|[JSON/читаемая сводка и CI snapshot drift](RELEASE_COMPARISON.md); реальные сопоставимые before/after условия и семантические измерения ещё требуются|
|45|P1|Docs/CI truth|реализовано в текущем срезе; общий drift gate открыт|Current source/release/site scopes and docs; new4shardCI/localdriververified; completeclaim drift future|

## Развитие WebKit

|Срез|Приёмка|
|---|---|
|Вкладки/popup|CmdT/W, последнее закрытие, sameprofile store, two-profile cookie/LS/IDB isolation, opener ownership и штатныйquit|
|Proxy|Новая revocable capability/sessionauthority, credentialsневargv/log, noDirectfallback; controlledDNS/RTC/loopback/IPv6/redirect/worker tests|
|Downloads|WKDownload фактическиеbytes/hash, filechoice, collision/symlink/cancel/redirect/TLS; неURLSession bypass|
|Sessionrestore|Опубликовано0.8.7: exact signed ⌘Q/processrestart2tabs/order/selected/fullURLs; nativeA/B storage/clone/savefault/retry PASS. Crashlast-unsaved/forms/history не обещаются.|
|MCP GUI|AuthenticatedlocalIPC/revision/sessionownership; noJS/shell/secretaccess|
|Данные|Owned closedstore safe delete/cache; public snapshot APIs исследовать доfullbackup promise|

## Принятые ограничения

- Default-system-trusted authenticated HTTPSupstream positive отложен пользователем до подходящего сервера.
- AdditionalMac/macOS14/second-display/mediahardware требуется реальнаясреда; mock не закрываетgate.
- Fullbackup переносencryptedsecretsмеждуMac не заявляет.
- Major1.0 все45пункты и расширениеWebKit не подменяются опубликованнойpublicalpha.
- AffPapa исключён; каналыGitHub иbrowser.free.

Зависимости, тесты и критерии приёмки каждого пункта сохранены в `major-plan.json` активной задачи. Ссылка на её CURRENT находится в индексе контекста проекта.
