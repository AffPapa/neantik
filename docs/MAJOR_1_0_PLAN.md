# NeAntik: план до версии 1.0

Последний завершённый выпуск — [0.8.15 (127)](../releases/v0.8.15.json). Он не закрывает всю приёмку 1.0. Точная очередь незавершённого и принятие ограничений — в [NEXT_1_0_SLICES](NEXT_1_0_SLICES.md); исторические результаты ниже не требуют повторного выполнения без изменения входов.

В127 опубликован recovery pin, завершён signed WebKit startPage-контроль, выполнен controlled DNS raw-runtime срез. Manager/relay DNS integration, фоновые запросы и смена сети остаются открытыми; WebKit proxy/GUI-MCP/media/backup не объявляются готовыми. [Приоритеты следующих срезов](NEXT_1_0_SLICES.md) отделяют эти задачи от уже пройденного. Исследование Fury сохранено; код его AGPL-компонентов в продукт не копируется.

## Очередь работ

1. **Быстрее разрабатывать.** Общие кэши, четыре CI-сегмента, точечный выбор тестов, защита от параллельной записи в кэш и компактные правила. Локальная проверка инструментов выполнена; CloudCI301 выполнен; очередь macOS ARM и cold build учтены отдельно.
2. **Вкладки WebKit.** Новая вкладка, переключение, закрытие и ссылки, открывающие новое окно. Все вкладки одного профиля используют его хранилище. Данные разных профилей разделены. Опубликовано в0.8.3: exact signed WebKit A/B full restart, public bytes и downloaded launch проверены.
3. **Сеть и удобства WebKit.** Загрузки опубликованы в0.8.6, опциональное восстановление вкладок после штатного выхода — в0.8.7 (exact signed/hosted/headed/MCP проверены). Кэш закрытого WebKit-профиля опубликован в0.8.8: native/exact A/B, cookies/LS/IDB/SW/CacheStorage/session сохранены. Публичный SDK proxyConfigurations сам по себе не подтверждает DNS/WebRTC UDP; refusal остаётся. Прокси требуют отдельной revocable authority, DNS/WebRTC/no-Direct проверки; до них proxy launch запрещён. GUI-MCP и полный backup остаются открытыми.
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

## Все 45 пунктов

|№|Приоритет|Задача|Фактическое состояние|Следующее доказательство|
|---|---|---|---|---|
|1|P0|Шрифты|Подписанный runtime 0.8.3: профильные headed проверки прошли; полный пункт 1.0 открыт|Нативные fallback-шрифты всех аппаратных когорт; extended TextMetrics.|
|2|P0|Девять контекстов|Подписанный runtime 0.8.3: профильные headed проверки прошли; полный пункт 1.0 открыт|Операции проверены в девяти контекстах; не каждый API в каждом realm.|
|3|P0|Canvas чтения|Подписанный runtime 0.8.3: профильные headed проверки прошли; полный пункт 1.0 открыт|Дополнительные сочетания размеров/форматов и межверсионный контроль.|
|4|P0|Canvas инварианты|Точный runtime 0.8.11: copy/alpha/reset и реальные сломанные контроли проверены; полный пункт 1.0 открыт|Расширенная совместимость изображений и цветовых профилей.|
|5|P0|WebGL1/2|Подписанный runtime 0.8.3: профильные headed проверки прошли; полный пункт 1.0 открыт|Сопоставление GPU limits/renderer с каждой аппаратной когортой.|
|6|P0|Audio|Подписанный runtime 0.8.3: профильные headed проверки прошли; полный пункт 1.0 открыт|Физическое аудиооборудование и разрешения; дополнительные MessagePort ошибки.|
|7|P0|HTTP/JS identity|Подписанный runtime 0.8.3: профильные headed проверки прошли; полный пункт 1.0 открыт|HTTPS и cross-origin Client Hints вместе с сетевым маршрутом.|
|8|P0|Screen/geometry|Подписанный runtime 0.8.3: профильные headed проверки прошли; полный пункт 1.0 открыт|Второй физический дисплей и другие Mac/macOS.|
|9|P1|ClientRects|Подписанный runtime 0.8.3: профильные headed проверки прошли; полный пункт 1.0 открыт|Сравнение аппаратных когорт; текущие DOMRect/Range/scroll/zoom уже проверены.|
|10|P1|WebGPU|Подписанный runtime 0.8.3: профильные headed проверки прошли; полный пункт 1.0 открыт|WebGPU в профиле отключён; включение требует согласования capabilities.|
|11|P1|NetworkInformation|Подписанный runtime 0.8.3: профильные headed проверки прошли; полный пункт 1.0 открыт|Физическая смена сети и события.|
|12|P1|Battery|Подписанный runtime 0.8.3: профильные headed проверки прошли; полный пункт 1.0 открыт|Физическая смена питания и события.|
|13|P1|Память|Подписанный runtime 0.8.3: профильные headed проверки прошли; полный пункт 1.0 открыт|Сравнение RAM/heap/quota на других устройствах без их приравнивания.|
|14|P1|Speech voices|Подписанный runtime 0.8.3: профильные headed проверки прошли; полный пункт 1.0 открыт|Локальные голоса и события на других macOS; списки имён не публикуются.|
|15|P1|Media/permissions|Подписанный runtime 0.8.3: профильные headed проверки прошли; полный пункт 1.0 открыт|Реальные камеры/микрофоны и разные аппаратные конфигурации.|
|16|P1|Apple аппаратные когорты|Исследование и локальная реализация; приёмка 1.0 открыта|Уточнить покрытие по сохранённым отчётам; выполнить недостающие проверки поведения на финальном кандидате. Исследование не закрывает приёмку.|
|17|P1|Общие fingerprint когорты|Исследование и локальная реализация; приёмка 1.0 открыта|Уточнить покрытие по сохранённым отчётам; выполнить недостающие проверки поведения на финальном кандидате. Исследование не закрывает приёмку.|
|18|P1|Обычная web совместимость|Исследование и локальная реализация; приёмка 1.0 открыта|Уточнить покрытие по сохранённым отчётам; выполнить недостающие проверки поведения на финальном кандидате. Исследование не закрывает приёмку.|
|19|P0|Маршрут Chromium|проверено в ограниченном scope; manager DNS остаётся открыт|HTTP через relay ранее проверен. В127 добавлен headed raw signed runtime DNS/DoH срез:8наблюдений/3сессии; runtime-байты126=127. Следом manager/relay DNS и полный TLS/UDP scope.|
|20|P0|Отказ mid-session|проверено в ограниченном scope|Существующие2канала relay/отказ/восстановление сохранены. В127 raw-runtime SERVFAIL, stream cut и recovery прошли, Direct-контроль чувствителен. Manager DNS/failure integration и смена сети остаются открыты.|
|21|P0|WebRTC negatives|Исследование и локальная реализация; приёмка 1.0 открыта|Уточнить покрытие по сохранённым отчётам; выполнить недостающие проверки поведения на финальном кандидате. Исследование не закрывает приёмку.|
|22|P0|Фоновые запросы|Исследование и локальная реализация; приёмка 1.0 открыта|Уточнить покрытие по сохранённым отчётам; выполнить недостающие проверки поведения на финальном кандидате. Исследование не закрывает приёмку.|
|23|P1|Per-profile relay|опубликовано с ограничениями|HTTP/SOCKSauth relay and cleanup; HTTPSdefault-system-trust positive deferred; WebKitauthority separate|
|24|P1|Поэтапная proxy диагностика|опубликовано; полная матрица открыта|Stage-specific diagnostics exist; cross-enginefailure taxonomy to reconcile|
|25|P1|Явное определение протокола|Исследование и локальная реализация; приёмка 1.0 открыта|Уточнить покрытие по сохранённым отчётам; выполнить недостающие проверки поведения на финальном кандидате. Исследование не закрывает приёмку.|
|26|P1|Свой endpoint|опубликовано; endpoint-specific route scope|Custompreflight and signed browser endpoints; privacy/DNS limits preserved|
|27|P1|Активный network status|реализовано; lifetime matrix открыта|Revision/session observation implemented; continuous/allprotocol freshness acceptance open|
|28|P2|Domain allow/block|Исследование и локальная реализация; приёмка 1.0 открыта|Уточнить покрытие по сохранённым отчётам; выполнить недостающие проверки поведения на финальном кандидате. Исследование не закрывает приёмку.|
|29|P2|WireGuard/profile|исследование завершено с обоснованным решением|WireGuard deferred by justified infrastructure/product design gates|
|30|P1|Full encrypted backup|опубликовано с ограничениями|Real signedQA restore cookies/LS/IDB/tabs and interruption; sameMac/Keychain only. В127 опубликован profile/journal recovery pin с реальными файловыми negative controls и безопасной формой; WebKit snapshot остаётся открыт.|
|31|P1|Clone vs restore|реализовано и проверено локально|Clone newidentity vsrestore original; noCrossMacsecret portability|
|32|P1|Cachecleanup|опубликовано publicalpha|Chromium safe cacheallowlist сохранён; WebKit HTTPdisk/memory cache0.8.8: native/exact A v2/Bv1, cookies/LS/IDB/SW/CacheStorage/session сохранены. Без размера/CodeCache/private paths; major hardware/OS coverage открыта.|
|33|P1|Extension center|опубликовано с ограничениями|Extension inventory/provenance+ownCRX native lifecycle; notuniversalinstallation|
|34|P1|CRX provenance|реализовано и проверено локально/на runtime|Full CRX3crypto checks and ownnative lifecycle; canceldialog unobserved|
|35|P1|Импорт|реализовано; ограниченная квалификация|Owned bookmarks import; noencryptedsecret import promise|
|36|P1|Graceful data close|проверено в ограниченном scope|Owned signed runtime/backup/updater durability; broader crash/timeout matrix open|
|37|P1|Проверенный updater|опубликовано с ограничениями|Exact signed088→0810 install/ACK/relaunch + preACKrollback; metadata2profiles unchanged; feeds live. Futuremedia/multihop/data/OS gates open|
|38|P2|Bounded MCP observation|частично опубликовано|18management/7read tools; boundedbrowser observation/GUIIPC and realAIclient gates open|
|39|P2|Self-hosted team|исследование завершено с обоснованным решением|No teaminfra productdecision; noimplementationclaim|
|40|P0|One vector patch+test|Исследование и локальная реализация; приёмка 1.0 открыта|Уточнить покрытие по сохранённым отчётам; выполнить недостающие проверки поведения на финальном кандидате. Исследование не закрывает приёмку.|
|41|P0|Positive/negative controls|Исследование и локальная реализация; приёмка 1.0 открыта|Уточнить покрытие по сохранённым отчётам; выполнить недостающие проверки поведения на финальном кандидате. Исследование не закрывает приёмку.|
|42|P0|Values vs behavior|Исследование и локальная реализация; приёмка 1.0 открыта|Уточнить покрытие по сохранённым отчётам; выполнить недостающие проверки поведения на финальном кандидате. Исследование не закрывает приёмку.|
|43|P0|Exact shipped browser|0.8.15(127) опубликована public alpha; major1.0 открыта|[Точная подпись/Apple ZIP+DMG/Gatekeeper/hosted/headed/WebKit/MCP и live Site152](../releases/v0.8.15.json); прежние platform observations сохранены в их scope. Все45/OS/hardware gates не закрыты.|
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
