# NeAntik changelog

## Direct 0.8.17 (129) — published public alpha — WebKit через MCP

- Запуск, статус и остановка WebKit доступны через открытый интерфейс NeAntik после явного разрешения подключения и выбранных профилей. Повторное подключение не получает чужие окна.
- Отключение AI и отзыв доступа оставляют окна пользователю. Остановка ожидает сохранения вкладок и завершения загрузок; ошибка сохранения не обозначается как успешное закрытие.
- Исправлено закрытие WebKit при открытом диалоге загрузки: сначала отменяется собственная загрузка и завершается callback, затем закрывается окно. Старый отказ и исправленный оконный сценарий сохранены.
- Активная проверка отпечатка теперь завершает только собственную временную сессию независимо от фоновой паузы интерфейса. Launch-разрешение остаётся одноразовым; отдельный completion permit проверяет owner, каталог, отмену и неизменность lease после ожидания.
- Локальная интеграция и затронутые delta-наборы, подписанный Dev UI и точный кандидат проверены в указанном scope. Apple ZIP/DMG, Gatekeeper, публичные байты и downloaded MCP18/7 прошли. GitHub опубликован; browser.free пока остаётся на0.8.16 из-за отказа автоматической проверки передачи Sites credential. Chromium156, сертификат и форматы данных не менялись. [Отчёт и ограничения](releases/v0.8.17.json).

## Direct 0.8.16 (128) — published public alpha — удаление WebKit

- Реализованы удаление закрытого UUID-хранилища через public WebKit API и отдельное необратимое подтверждение. Журнал защищает запуск и позволяет явно продолжить прерванную операцию.
- Перед нативным удалением профиль исключается из обоих metadata snapshots, включая защиту от запуска старой127. Ошибка сохранения не возвращает удалённую запись в интерфейс; очистка пароля следует за долговечным commit.
- Каталог NeAntik изолируется через descriptor-based rename и проверку inode. Удаляются только пустые служебные папки; неожиданные локальные файлы сохраняются с предупреждением. Chromium Trash-путь не менялся.
- Итоговая Swift-интеграция1572/183 (1498passed log lines,71explicit skips) и Python1482/19skips прошли. После filesystem correction пройдены3fresh source-native фазы и точные signed GUI удаление A/сохранность B, очистка собственных UUID и recovery после перезапуска. Exact headed128, doctor13, Apple ZIP/DMG, Gatekeeper, публичные байты, downloaded MCP и browser.free153/live прошли. Пропуски и границы — в [отчёте](releases/v0.8.16.json).
- Chromium156.0.8078.12, сертификат, identity и формат WebKit-сессий сохранены. Это public alpha, не завершённая1.0. [0.8.15](releases/v0.8.15.json) сохранена для отката приложения; удалённые данные сайтов не восстанавливаются downgrade.

## Direct 0.8.15 (127) — published public alpha — безопасный выбор восстановления

- Подтверждение восстановления привязано к выбранному профилю и конкретному журналу. Wrong-profile и stale-stage отказываются до изменения данных; профильное окно не предлагает завершить чужое/неподтверждённое восстановление.
- Полные Swift/Python и новые recovery units, canonical Dev GUI, exact signed headed127, signed WebKit startPage control, doctor13, JS/HTTP DeviceMemory, Apple ZIP/DMG, hosted bytes, downloaded MCP и browser.free152/live прошли. Пропуски и границы — в [отчёте](releases/v0.8.15.json).
- Новый controlled DNS/DoH срез прошёл на headed signed runtime:8наблюдений/3сессии, SERVFAIL/обрыв/восстановление и чувствительность к Direct обходу. Это raw runtime, не завершение manager/relay и всех19–22.
- Doctor больше не создаёт executable Python bytecode через потомков. Chromium156, identity, backup/metadata/session schemas и существующие updater helpers сохранены. [0.8.14](releases/v0.8.14.json) остаётся для отката; это не завершённая1.0.

## Исходные инструменты после 0.8.14

- Анонимный hosted-downloader использует системный curl без пользовательского конфига/ambient credentials и редактирует ошибки; настоящий отрицательный контроль ловит незапрошенную передачу собственного тестового файла.
- Fast runner запрещает bytecode Python-потомкам тестов. CI проверяет вводные release-ссылки README и fine-grained GitHub tokens, не выводя их значения. Исправлен текущий сетевой инвентарь и очередь 1.0.
- Это source-only изменения инструментов. Неизменяемые бинарные assets 0.8.14 относятся к app-source commit 77edb549ebd634f84064de77460cb7e38ea15e1c.

## Direct 0.8.14 (126) — published public alpha — автоматическое сохранение вкладок WebKit

- Режим «Предыдущие вкладки» сохраняет подтверждённые адреса, порядок и выбор вкладки автоматически, объединяя быстрые изменения в короткое окно. Непрерывные изменения не откладывают запись бесконечно. Выключенный режим не создаёт session-файл; частично восстановленная сессия не заменяет исходную.
- Одна очередь записи объединяет быстрые изменения; закрытие ждёт текущую запись и сохраняет окончательный список последним. Запись атомарная; ошибка показывается без циклических повторов. После ошибки операция не выдаётся за успешно завершённую.
- Четыре реальных оконных сценария прошли без пропусков; на точном signed-кандидате подтверждены autosave до закрытия, History API и удаление вкладки из файла. Дополнительный signedB запуск остановлен сохранённой защитой памяти и не засчитан как PASS. Это не полный backup сайтов.
- Swift integration, exact headed, doctor13, Apple ZIP/DMG/stapling/Gatekeeper, публичные байты, downloaded MCP smoke и browser.free151/live проверены. [Отчёт и ограничения](releases/v0.8.14.json).
- [Следующие приоритеты 1.0 и ограничения WebKit](docs/NEXT_1_0_SLICES.md).

## Direct 0.8.13 (125) — GitHub/browser.free public alpha

- Исправлена проверка SOCKS5: логин проверяется после той же нормализации, что используется при сохранении. Значимые пробелы в пароле сохраняются.
- WebKit соблюдает общий интервал между успешными запусками профилей. Неуспешный запуск освобождает слот без задержки.
- Стартовая страница, адресная строка WebKit и MCP принимают адреса с портом: `example.com:8443`, `localhost:8080`, `[::1]:8080`. Неизвестные схемы, credentials и неверные порты отклоняются.
- MCP возвращает `engineCapabilities`: поддержку настройки окружения, прокси, запуска через MCP, расширений, backup и постоянных данных сайтов. Это возможности движка, а не результат проверки текущей сессии.
- WebKit с явно сохранённым Chromium context языка/часового пояса отказывается запускаться вместо молчаливого игнорирования настройки. Старые metadata остаются читаемыми и не стираются. Системный WebKit не подменяет полный fingerprint.

- Опубликованы неизменяемые ZIP/DMG; exact headed/MCP, Apple notarization/stapling/Gatekeeper, публичные байты и downloaded stdio smoke проверены. Сайт обновлён до версии150. [Отчёт](releases/v0.8.13.json).

### Ранее подготовленные исправления, включаемые в кандидат125

- Сохранён `profile_not_stopped`; добавляется фиксированная причина отказа и подходящее действие. Неизвестное владение больше не описывается как установленный факт запущенного браузера. Защита metadata и запрет автоматического повтора сохранены.
- Исправлено двойное чтение температуры: переход critical→serious ошибочно пропускал запуск через два сравнения. Теперь используется одно наблюдение. Memory-pressure guard не ослаблен.
- Legacy/modern JSON-RPC проверки используют синтетические metadata, real regular/symlink lease fixtures, unknown/found/absent controls и mock Keychain. Исправлено влияние ambient OS pressure на три теста tombstone; production поведение не изменено этой настройкой тестов.
- Старый thermal guard реально отклонён новым deterministic тестом; исправленный и семь связанных наборов прошли114 reported/111passed/3explicit skips. Это локальная разработка, не квалификация подписанного релиза; текущие124 ZIP/DMG неизменны.

## Direct 0.8.12 (124) — GitHub public alpha — audit lifecycle

- Добавлен внутренний защищённый режим удаления временного ключа fingerprint-аудита без повторного A→B→A. Проверяются вызывающий процесс, точный подписанный кандидат, manifest inventory и отдельное подписанное разрешение на удаление. Квитанция очистки не является отчётом готовности релиза.
- Подписанный intent сохраняется до удаления; повтор после сбоя проверяет отсутствие ключа и reservation, не создавая новую authority. Нативная проверка Secure Enclave/Keychain на точном подписанном кандидате пройдена.
- Нативная проверка кандидата123 выявила пропуск framework descendants при вызове `skipDescendants()` для символьной ссылки. Валидатор исправлен; реальный и синтетический framework inventory совпадает полностью. Кандидат123 сохранён для диагностики и не опубликован.
- Исправлены противоречивые инструкции повторных прогонов и гонка EOF/ledger в тесте стенда. Chromium остаётся156.0.8078.12; публичные артефакты0.8.11 сохраняются. ZIP/DMG опубликованы на GitHub; сайт и downloaded headed gate пока не завершены. [Отчёт](releases/v0.8.12.json).

## Direct 0.8.11 (122) — published public alpha — proxy check freshness

- Список профилей обновляет возраст сохранённой проверки прокси раз в минуту. Устаревший результат перестаёт выглядеть успешным даже при остановленных профилях. Это обновление текста/значка, без новых сетевых запросов и изменения настроек.
- Исправлена подготовка кэшированной Dev.app, в которой отсутствовал новый служебный ключ. Проверка открытых исходников поддерживает текущие ZIP/DMG checksum records и прежний формат ZIP; конфликты и повреждения отклоняются.
- Отдельный DEBUG QA-режим теперь измеряет фоновые попытки без отключения background/component/sync/extensions. В 80-секундной записи точного M156 все пять HTTP(S) попыток выбрали relay, одна завершилась ошибкой при отказе; настоящий Direct-контроль распознан. Это не доказательство отсутствия DNS/UDP на проводе и не новая пользовательская диагностика.
- Chromium156.0.8078.12, profile identity/schema и существующий сертификат сохраняются. WebKit media/proxy/extensions/full backup остаются недоступны. Версия опубликована; подпись, точный runtime/GUI, updater hop, Apple и hosted gates пройдены. Глобальная1.0 остаётся открытой.

- Exact headed/DeviceMemory/MCP18/7, doctor13, AppleZIP+DMG/stapling/Gatekeeper, native0810→0811install/ACK/relaunch+preACKrollback, 4GitHubdigests, anonymoushostedbytes/downloadedheaded/MCP/DMG, Sites148/live dualfeeds PASS. [Доказательства и ограничения](releases/v0.8.11.json).

## Direct 0.8.10 (121) — published public alpha — signed installer continuity

- Сохранены предыдущие подписанные модули; новая primary-пара размещена в фиксированном V2-каталоге. Подпись, сертификат, SHA-256 и CodeDirectory проверяются; malformed V2 не откатывается к legacy. Packaging защищён от временной подмены файлов во время проверки и пропущенного continuity input.
- Настоящие 0.8.8→0.8.10 install/ACK/relaunch и pre-ACK rollback PASS; два синтетических metadata-only профиля сохранились без изменения байтов. Клавиатура/editor/WebKit choice и отмена черновика проверены. Это не новый свежий cookie durability gate.
- Developer ID/Apple ZIP+DMG/stapling/Gatekeeper/doctor13/draft4digests/anonymoushostedbytes/freshdownloadedheaded/MCP/Sites147/live dualfeeds PASS. Первая downloaded попытка отказала по ресурсам; после снижения нагрузки свежий отчёт проверен, защиты сохранены.
- Chromium156.0.8078.12 и сертификат прежние. WebKit media остаётся disabled; глобальная1.0/аппаратная квалификация открыты. [Доказательства и ограничения](releases/v0.8.10.json).

## Direct 0.8.9 (120) — development candidate — updater transition

- Готовится переходный выпуск с прежними правами подписи. Новый validator умеет проверять будущие camera/audio-input claims по signed purpose strings; дополнительные и неполные права отклоняются. У уже выпущенного0.8.8 validator не меняется.
- Камера и микрофон WebKit в этом кандидате отключены: нет новых прав устройства или purpose strings, настройки не показываются и MCP их не предлагает. Media-функция остаётся в разработке до реальной проверки capture, отказа, отзыва и прежнего разрешения сайта.
- Signed Info кандидата указывает отдельный канал `/api/update-v2.json`; старый канал должен предложить переходную версию старым клиентам. Feeds, точный native переход и публикация пока не квалифицированы. Старые архивы и rollback сохраняются.
- Полный Swift1529reported/178suites PASS. Python1354 первоначально обнаружил отсутствующий changelog нового кандидата; после добавления записи повторяются только затронутые documentation contracts. Developer ID/Apple/hosted и native install ещё не PASS.
- Этот кандидат не опубликован: настоящая проверка 0.8.8→0.8.9 отказала до установки из-за изменения модуля установщика. Подписанные архивы сохранены для диагностики; исправление продолжается в 0.8.10 (121).

## Direct 0.8.8 (119) — published public alpha — WebKit cache

- Очистка HTTP-кэша закрытого WebKit-профиля стала доступна из меню профиля. Удаляются только временные файлы страниц в памяти и на диске; cookies, LocalStorage, IndexedDB, Service Worker, CacheStorage и предыдущие вкладки не входят в очистку. Точный объём WebKit не показывает.
- Во время очистки запуск и изменение этого профиля защищены от второго менеджера. Выход и обновление ждут завершения операции. Отмена действует до обращения к WebKit; после него операция ждёт настоящего завершения.
- Раздел редактора «Запуск и оформление» теперь прямо указывает, где настроить стартовую страницу и предыдущие вкладки. Прокси, расширения и полный backup WebKit остаются недоступны.
- Full Swift1521reported/176suites и Python1352 PASS; отдельные native и exact signed UI подтвердили A v2/Bv1 с сохранением данных. Developer ID/Apple ZIP+DMG/stapling/Gatekeeper/hosted/headed/MCP/Sites146/live feed проверены. Cloud CI dispatch403; облачный PASS не заявляется. [Доказательства и ограничения](releases/v0.8.8.json).

## Direct 0.8.7 (118) — published public alpha — WebKit session restore

- В WebKit можно выбрать «Предыдущие вкладки»: после штатного закрытия сохраняются адреса, порядок и выбранная вкладка. Полные HTTP(S) адреса с query/fragment хранятся отдельно в приватном файле профиля, без включения в MCP или metadata export.
- Обычные закрытие и ⌘Q ждут завершения записи и отмены загрузок. При ошибке записи профиль остаётся занят; «Остановить» повторяет сохранение. Повреждённая сессия открывает стартовую страницу с предупреждением; частичное восстановление из-за нехватки памяти не заменяет прежний полный список.
- Настройка доступна в редакторе и MCP metadata. Стдио-запуск WebKit, прокси, расширения и полный backup WebKit остаются недоступны. Переименование сохраняет сессию; копирование создаёт новый UUID и пустую сессию.
- Отключение очищает только список вкладок после окончательного metadata/credential commit. Ошибка очистки возвращает сохранённую настройку с предупреждением; повторное включение требует очистки прежнего OFF списка.
- Полный Swift regression и Python1352 PASS; real headed3 session tests, Dev GUI и exact signed ⌘Q/перезапуск прошли. Apple ZIP/DMG, Gatekeeper, hosted bytes, downloaded headed/MCP и Sites144/live feed проверены. [Доказательства и ограничения](releases/v0.8.7.json). Для отката к0.8.6 сначала верни WebKit к режиму «Стартовая страница»; прежняя версия не поддерживает его restoreSession.

## Direct 0.8.6 (117) — published public alpha — WebKit downloads

- WebKit получает собственные загрузки: выбор места сохранения, прогресс, отмена и показ файла в Finder. Сохранение через временный файл и exclusive rename не перезаписывает существующие файлы.
- Закрытие профиля и выход ждут подтверждённой отмены; pending policy conversion учитывается до появления WKDownload.
- Реальные синтетические HTTP/attachment/blob, cookiesA/B, отмена, раннее закрытие и Dev SavePanel/⌘Q проверены; точный подписанный кандидат и скачанные ZIP/DMG прошли native/Apple/Gatekeeper, headed/MCP и live Sites143 проверки. Chromium156.0.8078.12 сохранён. [Результаты и ограничения](releases/v0.8.6.json).

## Direct 0.8.5 (116) — published public alpha — profile management and UTC release checks

- Сохранены исправления статуса прокси, завершения процессов и копирования профилей без лишнего обращения к Связке ключей из кандидата 0.8.4.
- Дата проверки безопасности теперь считается по UTC одинаково на локальном Mac и CI. Проверки будущей и просроченной даты сохранены; тесты времени имеют заданную дату.
- Chromium 156.0.8078.12 не пересобирался. Подпись, notarization, stapling, Gatekeeper, публичные ZIP/DMG, свежий headed запуск и metadata MCP проверены. [Результаты и ограничения](releases/v0.8.5.json).
- 0.8.4 не опубликована: её принятый Apple ZIP сохранён как неизменяемый результат проверки и продолжения транзакции. Опубликована 0.8.5; 0.8.3 сохранена для отката.

## Direct 0.8.4 (115) — release candidate — proxy status and safe shutdown

- Результат проверки прокси сохраняется при обычной отметке запуска. GUI и MCP используют подтверждение сохранённого перехода; смена пароля или конфигурации не наследует старый результат.
- Ожидание вспомогательных процессов больше не обозначается как повреждение файла. Разблокировка по-прежнему требует безопасной проверки завершения.
- Копирование через MCP/интерфейс и открытие редактора профилей без авторизации прокси больше не зависят от доступности Связки ключей. Для прокси с авторизацией сохранены чтение пароля и безопасный отказ при ошибке; устаревшее сообщение MCP о запрете SOCKS5 удалено.
- Lifecycle-тесты получают явное состояние нагрузки; отдельные отрицательные проверки требуют отказ при нехватке памяти и критической температуре. Приложение продолжает использовать системный admission.
- Local: 153 targeted tests passed; full Swift summary1483/168suites (59skip lines) and Python1307 (19skips) passed. Dev CmdN/create/select/save/quit verified on one disposable profile. Exact signed candidate and publication remain pending; public release is still0.8.3.

## Direct 0.8.3 (114)

Published public alpha on GitHub and browser.free Sites141. Chromium156.0.8078.12 unchanged. Exact signing/notarization/stapling/Gatekeeper, public ZIP/DMG bytes, fresh downloaded headed launch and metadata MCP PASS. [Results and limits](releases/v0.8.3.json).

- WebKit: вкладки, ⌘T/⌘W, переключение и ссылки в новой вкладке внутри того же профиля. Закрытие последней вкладки останавливает профиль; команда Stop закрывает всё его окно.
- Выбор Chromium/WebKit двумя видимыми кнопками. Активная вкладка выделена; добавлены подсказки клавиатуры и справка.
- Всплывающие окна без действия пользователя заблокированы; до 32 вкладок, при нехватке памяти новые не создаются.
- 1479 Swift tests / 168 suites passed locally. Headed own WebKit fixtures verify same-profile sharing, A/B cookie/LocalStorage/IndexedDB isolation, cleanup and popup negative control. Dev GUI and exact signed WebKit A/B full restart passed. Local reported counts include optional skips; separate native fixtures and public-byte gates are recorded.
- CI uses four clean shards with separate suite processes, scoped check recommendations and one lease per physical developer cache. Release gates are retained.
- WebKit proxy, downloads, session restore, extensions, full backup and stdio MCP launch remain unsupported. Public alpha; full major1.0 acceptance remains open.

## Direct 0.8.2 (113)

Published public alpha on GitHub and browser.free Sites140. Chromium156.0.8078.12 and the Developer ID are unchanged. [Exact results and limits](releases/v0.8.2.json).

- Исправлено воспроизведённое падение карточки прокси при чтении accessibility label. Выбор, изменение и сохранение проверены в точном подписанном ZIP.
- Штатный authenticated HTTP relay, HTTP/HTTPS destination, отказ upstream и Direct negative control проверены на синтетических профилях; это ограниченные наблюдения, не whole-session DNS/UDP guarantee.
- Fast developer tests используют общий project cache и batched suites, jobs2/serial; пустая выборка не даёт PASS.1477reported tests/168suites/59optional skips,74.088s.
- ZIP/DMG notarization/stapling/Gatekeeper и публичные байты PASS; скачанный manager/Chromium и metadata MCP PASS. WebKit preview и прежние ограничения сохранены; rollbackv0.8.1.

## Direct 0.8.1 (112)

Published public alpha on GitHub and browser.free Sites139. Includes WebKit preview from unpublished0.8.0. Chromium156.0.8078.12 unchanged. Exact signed, WebKit native persistence, Developer ID/notarization/stapling/Gatekeeper, public ZIP/DMG bytes, downloaded headed/MCP and live feed PASS. [Results and limits](releases/v0.8.1.json).

- Исправлена live-code классификация посторонних процессов и ожидание завершения транспорта updater.1477reported Swift tests/168suitesPASS.
- Native packed CRX lifecycle и exact WebKit A/B full restart PASS; это ограниченные синтетические сценарии. DNS/default-trusted HTTPS upstream и major1.0 остаются открытыми. Rollbackv0.7.47; schema2 metadata не открывать старым manager.

- Импортируемые адреса и учётные данные прокси скрыты от стандартного debug-вывода Swift; парсинг и сохранение значений не изменены. Отрицательный контроль воспроизвёл прежний отказ, 13 targeted tests PASS.
- Изолированная авторизованная проверка updater явно открывает окно manager после предыдущего закрытого окна. Она не запускает fingerprint-аудит автоматически и не обходит авторизацию. 12 targeted launch tests PASS.
- В осмотре установленных расширений доступны локализованные имена вместо `__MSG_*`; это не новый центр управления и не доказательство native packed CRX installation.
- Qualification aggregator требует полные отрицательные контроли; timeout наблюдения голосов означает inconclusive, а не PASS. Это изменение harness, не browser fingerprint policy.
- Перед переносом и заменой локального bundle release-скрипты проверяют отсутствие работающего manager и вложенного браузера; при обнаружении процессов выпуск останавливается. После компиляции выполняется повторная проверка. Это не атомарная блокировка нового запуска.

## Direct 0.8.0 (111)

Public-alpha candidate; not yet published. Exact signed app, notarization, hosted bytes and WebKit smoke remain release gates. Chromium 156.0.8078.12 is unchanged.

- При создании профиля можно выбрать Chromium или системный WebKit — движок Safari. WebKit открывается в собственном окне NeAntik с адресной строкой и командами навигации; это не Safari.app и не эмуляция Safari в Chromium.
- У WebKit-профиля отдельное постоянное хранилище cookies, LocalStorage и IndexedDB. Изоляция двух синтетических профилей и сохранение после штатного перезапуска проверены в Dev.app; старые профили остаются Chromium. Движок существующего профиля менять нельзя.
- Движок сохраняется в настройках, копировании, шаблонах и MCP metadata tools. Данные с WebKit используют schema 2: старые версии менеджера не должны их открывать. Перед обновлением сохраните отдельную копию настроек; она не является backup данных WebKit.
- WebKit — preview: только прямое подключение, одно окно без вкладок; прокси, расширения Chromium, полный backup, очистка кэша и удаление явно недоступны. Профиль можно архивировать. Запуск через MCP stdio требует будущего GUI IPC и сейчас отклоняется. [Возможности и ограничения](docs/WEBKIT_PROFILES.md).
- Внутренний протокол relay передаёт привязанное к сессии наблюдение маршрута с проверкой срока действия и revision. Полная HTTPS/DNS-квалификация не завершена; MCP по-прежнему не объявляет маршрут Chromium доказанным.
- Интеграция: 1467 тестов / 166 suites PASS, 56 явных skips; signed QA подтвердил HTTP browser ACK и отрицательный HTTPS-контроль. Это не заменяет проверку поставляемого кандидата.

## Direct 0.7.47 (110)

Published public alpha on GitHub and browser.free (Sites 136). Chromium 156.0.8078.12 is unchanged. [Release evidence](releases/v0.7.47.json).

- Исправлены два подтверждённых отказа updater: закрытые standard descriptors мешали bootstrap; сериализация одинакового подписанного plist давала различный порядок ключей. Сравнение учитывает все значения, типы и порядок массивов; доверие подписи не ослаблено.
- 1426 тестов / 164 suites PASS; реальные отрицательные контроли воспроизводят прежние отказы. Точная подписанная установка 0.7.46 → 0.7.47, управляемый сбой до ACK, откат, успешный commit и автоматический перезапуск проверены на изолированных данных.
- После установки восстановлены две вкладки и свежие cookies/LocalStorage/IndexedDB тестового профиля A; профиль B не получил эти данные. Исходная .46 — отдельная подписанная QA-база, не публичный и не нотарифицированный релиз.
- ZIP/DMG прошли Developer ID, notarization, stapling, Gatekeeper, проверку скачанных байтов и свежий headed запуск. Сайт отдаёт подписанный Ed25519 feed; установленная .47 проверила его по HTTPS в настоящем интерфейсе.
- Создание зашифрованного backup включено в квалифицированной упаковке; сохраняются ограничения исходного профиля/Mac/Keychain/runtime. Полный CRX installer и окончательная квалификация наблюдения маршрута остаются открытыми. Предыдущий публичный релиз .34 сохранён без изменения assets.

## Direct 0.7.43 (106)

Public-alpha candidate. Publication requires the exact signed .42 → .43 installation, controlled rollback and BrowserData persistence checks.

- Рабочий updater сохраняет дескрипторы для запуска новой версии после закрытия manager. Подписанный канал, явное согласие, проверка приложения и откат сохранены.
- 1421 Swift-тест / 162 suites прошли, включая реальные subprocess controls старого отказа и исправленного запуска. Повторный полный прогон для изменения только номера версии не требуется.
- Chromium 156.0.8078.12 и Developer ID сертификат сохранены. Авторизованный relay, зашифрованная копия закрытого профиля, центр расширений и MCP входят в кандидат; перенос OS-encrypted входов между Mac и полный CRX installer остаются ограничениями.

## Direct 0.7.42 (105)

Private corrected qualification candidate; not published.

- Исправлен отказ рабочего updater до запуска новой версии: после завершения диалога старые каналы заменяются на `/dev/null`, а дескрипторы 0–2 остаются занятыми для безопасного создания приватных bootstrap pipes.
- Реальные subprocess regression controls: прежнее закрытие stdio отказывает до spawn; исправленный handoff запускает и дожидается своего дочернего процесса. Подпись, согласие, custody, ACK и rollback gates сохранены.
- Точная подписанная установка, контролируемый сбой, BrowserData persistence и публикация ещё не квалифицированы.

## Direct 0.7.41 (104)

Public-alpha candidate; exact paired .40 → .41 installer, rollback, persistence and publication are pending.

- Same manager and fixed helper code as private .40; version-only transition for real signed updater qualification.
- Окно закрывается до выхода приложения; истёкшее предложение установки требует новой проверки.
- Сохранены подписанный канал, авторизованный relay, зашифрованный backup закрытого профиля, центр расширений и MCP. Ограничения каталога установки, CRX и переноса OS-encrypted данных на другой Mac остаются явными.

## Direct 0.7.40 (103)

Private paired qualification candidate; not published.

- Окно обновления закрывается до штатного выхода manager: AppKit больше не получает запрос завершения при открытом modal sheet. То же правило применяется к безопасному выходу после ошибки.
- Предложение установки ограничено сроком: до timeout owner оно снимается, owner завершается и требуется новая проверка файлов.
- 1421 Swift-тест / 162 suites PASS. Реальные installation, rollback и сохранность синтетических BrowserData остаются обязательными gates.

## Direct 0.7.39 (102)

Private candidate retained; native update-sheet termination defect was reproduced before publication. Not published.

- Исправлены admission и bootstrap updater: историческое происхождение runtime проверяется отдельно от подписанной справки о текущем релизе, с общими ограничениями размера.
- Подписанный канал описания обновлений, ручной выбор оригинального ZIP, подтверждение установки и перезапуск. Private key остаётся вне Git и сайта.
- 1420 Swift-тестов/162suites PASS. Chromium156.0.8078.12, Developer ID сертификат, per-profile relay, закрытый зашифрованный BrowserData backup и управление расширениями сохранены.
- Полные CRX lifecycle, перенос OS-encrypted входов на другой Mac и production hardware cohorts не объявляются квалифицированными.

## Direct 0.7.38 (101)

Release candidate; publication awaits exact paired installation and rollback.

- Исправлена проверка provenance при обновлении даты security baseline; исторические runtime bytes и reports остаются неизменными.
- Подписанный updater проверяет Ed25519 manifest, точный ZIP, Developer ID, runtime и системную оценку; установка требует подтверждения и закрытых профилей.
- Существующий Chromium156.0.8078.12, авторизованный per-profile relay, закрытый зашифрованный BrowserData backup и управление расширениями сохранены. Ограничения восстановления на другом Mac и CRX-инсталляции не скрыты.
- Локально:Общая проверка provenance используется до установки и при bootstrap: текущая security-справка проверяется отдельно, включая bounded byte budget. Положительные и отрицательные контроли прежнего bootstrap limit добавлены. Точная квалификация релиза записывается отдельно.

## Direct 0.7.37 (100)

Private qualification candidate; not published. Fixes the publication-baseline closure defect found in private0.7.35/0.7.36. Qualified earlier local artifacts are retained unchanged. Paired shipping installation remains pending.

## Direct 0.7.36 (99)

Development qualification candidate; not published.

- Same qualified Chromium156.0.8078.12 and Developer ID certificate as public0.7.34.
- Paired with private notarized0.7.35/98 to qualify the shipping updater, retained synthetic browser data, refusal and rollback. These installation results are pending.
- Signed update policy and explicit backup provisioning selection retained; public0.7.34 and its immutable downloads remain unchanged.

## Direct 0.7.35 (98)

Development qualification candidate; not published.

- Исправлено смешение исторической provenance движка и даты публикации: смена checkedAt больше не блокирует тот же точный runtime. Данные текущего релиза проверяются отдельно под подписью приложения.
- Упаковка сверяет runtime pins до подписи. После изменения: 1419 Swift-тестов / 162 suites, целевые отрицательные контроли и независимые Python измерения PASS; whole installation ещё проверяется.

- Pinned Ed25519 update policy and offline release-envelope signer; automatic downloads remain disabled.
- Authenticated interactive updater audit retains disposable storage and proves enrolled authority before startup; no fingerprint PASS is produced by this mode.
- Explicit macOS provisioning selection for BrowserData backup is checked before preparation. Public0.7.34 did not enable creation; the current candidate requests it using the existing certificate/profile.
-29 targeted Swift,1417/162 full Swift and32 targeted Python checks passed. Whole signed installation, bootstrap and rollback qualification remain open.
- Restored exact public0.7.34 checksum source sidecars missing from the release record; immutable public assets unchanged.

## Direct 0.7.34 (97) — public alpha

- Исправлена защита временных данных проверки: заменённая папка или symlink не используются для запуска и не удаляются при отмене. Неиспользованные разрешения запуска освобождаются.
- Изолированный release audit получает отдельные данные до чтения ProfileStore; обычные профили не получают mock Keychain.
- Исправлен SOCKS5-обработчик внутреннего relay; уточнена инструкция работы с CRX через Finder и Chromium.
- 1392 Swift-теста в 161 наборе прошли; 52 opt-in проверки пропущены; Dev.app и клавиатура, точный подписанный кандидат, публичные ZIP/DMG, свежие downloaded headed/MCP gates PASS. Сайт иAPI0.7.34/97, Sites 135. [Отчёт](releases/v0.7.34.json).
- Chromium 156.0.8078.12 и сертификат сохранены. Автоматический updater выключен; полный CRX installer открыт. Rollback 0.7.33. AffPapa пользователь обновляет вручную.

## Direct 0.7.33 (96) — public alpha

- Добавлена команда «Обновить NeAntik…»: понятная инструкция, ссылка на скачивание и предупреждение сохранить данные профилей. В этом выпуске обновление выполняется вручную.
- Подготовлен интерфейс проверки подписанного ZIP: отмена дожидается завершения установщика; повторные нажатия не создают второй сеанс; незавершённая очистка требует перезапуска и сохраняет блокировку.
- Операции с данными, импорт, восстановление, кэш, расширения и проверка прокси удерживают допуск до фактического окончания работы, включая отмену и публикацию результата. Это основа безопасной установки, а не заявление о готовом автоматическом updater.
- Локально: 1372 Swift-теста / 159 suites; Release build; Dev.app создание, запуск, остановка, клавиатура и сохранение metadata после перезапуска. Точный подписанный кандидат, публичные ZIP/DMG, скачанный headed manager и MCP прошли проверки. browser.free, Sites 134 и API 200 показывают 0.7.33/96. [Отчёт и ограничения](releases/v0.7.33.json).
- Chromium 156.0.8078.12 сохранён. Автоматический канал выключен до полного подписанного old→new gate; полный CRX installer остаётся в работе. Rollback 0.7.32.

## Direct 0.7.32 (95) — public alpha

- Авторизация HTTP, HTTPS и SOCKS5 через отдельный relay профиля; HTTPS проверяет сертификат до пароля и не переходит на HTTP/Direct при отказе.
- Обновлены подсказки сети, справка и MCP. Тесты собственного kernel record updater больше не зависят от посторонних процессов; production inventory остаётся полным и строгим.
- 1317 Swift-тестов; actual TLS/negative controls, headed relay и Dev keyboard/persistence PASS. Точный кандидат и публичные ZIP/DMG прошли Direct-гейты, скачанный headed manager и MCP. browser.free Sites133/API200 синхронизированы.
- Chromium 156.0.8078.12 не менялся. Full CRX installer и public updater открыты; rollback0.7.31. [Точный отчёт и ограничения](releases/v0.7.32.json).

## Direct 0.7.30 (93) — public alpha

- Зашифрованный backup BrowserData остановленного профиля: отдельный пароль архива и привязка к локальной Связке ключей. Настройки, прокси и папки экспортируются отдельно и сохраняются при restore. Неверный пароль и повреждённый архив не заменяют данные. Перенос авторизации между Mac не поддерживается.
- Явный выбор запуска: стартовая страница или предыдущие вкладки. Восстановление не добавляет стартовый адрес заново при каждом запуске; старые профили сохраняют прежний режим. Настройка доступна в редакторе и MCP.
- Режим сохраняется в копиях, шаблонах и configuration export; новая копия/import начинает с чистой identity и стартовой страницы.
- Исправлено двойное расширение имени backup. Direct opt-in требует проверенного macOS provisioning profile и существующего Developer ID сертификата; неподходящие claims отклоняются.
- 1140 Swift-тестов прошли; отдельный подписанный QA проверил настоящий изолированный Keychain, миграцию случайных proxy-паролей, encrypted restore, повреждения, прерывания, живые вкладки и повторный запуск без дублей. Production Keychain для тестов не использовался.
- ZIP/DMG опубликованы на GitHub и прошли свежие hosted signing/notarization/stapling/Gatekeeper и hash/size gates. Скачанный manager прошёл headed fingerprint и metadata MCP проверки. Подробные data/keyboard сценарии остаются отдельно связанным signed QA evidence. [Отчёт и ограничения](releases/v0.7.30.json).
- Chromium 156.0.8078.12 не менялся. HTTPS relay, CRX install и атомарный updater остаются отдельными незавершёнными частями программы.

## Direct 0.7.29 (92) — public alpha

- Центр расширений закрытого профиля: поиск, сохранённый статус, источник и запрошенные разрешения. Неполные данные явно отмечаются; внешние папки расширений автоматически не читаются.
- Установка, включение, отключение и удаление остаются в штатном интерфейсе Chromium. Центр объясняет переход через меню и позволяет скопировать адрес управления.
- Исправлен запуск управления расширениями: Chromium отвергает внутренний адрес в командной строке, поэтому открывается пустая вкладка с инструкцией перехода. Сохранённая стартовая страница не меняется.
- Backup использует единый контекст для экспорта и восстановления; production-операции удерживаются до квалификации подписи. QA-проверка не объявляется production-доказательством.
- 123 targeted и 1089 full Swift-тестов прошли; собственное расширение проверено в изолированном headed Dev с перезапусками и двумя профилями. Точный подписанный кандидат и скачанные ZIP/DMG прошли Direct gates; свежий headed запуск и MCP-проверка скачанного приложения прошли. [Результаты и ограничения](releases/v0.7.29.json).
- Исправлен дневной release gate: текущая security-справка упаковывается отдельно от неизменяемой записи проверки runtime; исторические хэши и происхождение сохранены. 36 release regression-тестов прошли.
- Chromium 156.0.8078.12 сохранён без пересборки. HTTPS relay, атомарный updater и major1.0 остаются в работе.

## Direct 0.7.28 (91) — public alpha

- HTTP и SOCKS5 с авторизацией подключаются через отдельный локальный relay профиля. Пароли остаются в Связке ключей и не попадают в аргументы Chromium. HTTPS-прокси сохраняет нативный способ авторизации.
- Relay переживает закрытие manager вместе с работающим браузером; повторный запуск защищён от дублирования. Отмена до активации не открывает соединение с upstream. Проверены два параллельных профиля и отказ upstream на синтетических fixtures.
- Исправлена изоляция паролей MCP для отдельных --data-root: совпавшие ID профилей больше не дают доступ к паролю основной библиотеки. Для прежнего custom workspace пароль нужно ввести заново.
- Карточки профиля получили простую структуру для accessibility; проверены создание с клавиатуры и отмена редактирования. Кнопка расширений открывает штатную страницу Chromium, сохраняя стартовую страницу.
- Полный backup BrowserData и атомарный updater остаются в разработке. Реальные QA-проверки восстановления не означают готовность их production-интерфейса.
- Chromium 156.0.8078.12 сохранён без пересборки. Safe Browsing остаётся отключённым; совместимость всех Mac и всех сторонних AI-клиентов не заявляется. Подписанные ZIP/DMG прошли Direct и hosted gates; скачанное приложение прошло свежую headed-проверку. [Результаты и ограничения](releases/v0.7.28.json).

## Direct 0.7.27 (90) — public alpha

- Проверка прокси и GeoIP автоматически показывают истечение срока результата; настроенные параметры не выдаются за независимое измерение.
- Снимок настроек добавляет новые профили без закрытия работающих браузеров. BrowserData и исходные профили не заменяются.
- Отмена проверки прекращает fallback и запросы к следующим сервисам. Уточнены ошибки DNS и timeout.
- Окно очистки кэша не закрывается во время операции; подсказка объясняет необратимую фазу удаления.
- Запуск и выбор профиля получили общие названия в меню и быстрых командах; справка и план проверяются CI.
- Chromium 156.0.8078.12 не пересобирался. Точный подписанный кандидат и публичные ZIP/DMG прошли Direct gates. [Результаты и ограничения](releases/v0.7.27.json).

## Direct 0.7.26 (89) — public alpha, 10 октября 2026

Промежуточное обновление manager с Chromium 156.0.8078.12. Подписанный кандидат и публично скачанные ZIP/DMG прошли release gates; публичное приложение прошло свежий изолированный headed запуск. GitHub и browser.free обновлены; affpapa.org ожидает restricted deploy credential. Глобальный план 1.0.0 остаётся открытым.

- Проверка списка медиаустройств и разрешений различает успешное чтение, отсутствие API, ошибку и timeout. Наличие API больше не выдаётся за успешную операцию; отчёт не содержит имён или ID устройств.
- Шрифты проверяются измерениями DOM и Canvas, повторным чтением и отсутствующим контрольным шрифтом. Загрузка ограничена по времени. Старый список названий шрифтов больше не допускает новый релиз.
- ClientRects отклоняет пустые, нечисловые и внутренне противоречивые результаты. Подробности диагностики отделяют базовое сравнение page/worker от полной квалификации платформы.
- Поддерживаемый headed harness связывает реальные операции первых15 пунктов плана с хэшами кандидата, framework и текущими исходниками. Он использует настройки, экспортированные настоящим Swift manager, и сохраняет независимые отрицательные контроли.
- Проверяются девять контекстов, способы чтения Canvas, WebGL, Audio, HTTP/JS identity, окна при масштабе100% и125%, память, IndexedDB и синтетическая камера/микрофон с отзывом разрешений. Эти тесты не устанавливают шрифты и не используют реальные профили или оборудование пользователя.
- Проверка второго физического дисплея, событий реальной смены сети/питания и всех моделей Mac остаётся отдельной. WebGPU по прежнему отключён в настроенном профиле; его операции проверяются отдельно в native control. Safe Browsing остаётся отключённым. Гарантии прохождения CAPTCHA или правил сторонних сайтов не заявляются.

## Direct 0.7.25 (88) — public alpha, 10 октября 2026

Manager-only обновление с прежним квалифицированным Chromium 156.0.8078.12. Собственные signing, headed runtime, notarization, Gatekeeper и hosted-byte проверки завершены; опубликованные байты прошли свежий headed запуск. Версия 1.0.0 пока не готова.

- Отмена проверки прокси и изменение пароля во время обновления metadata больше не публикуют устаревший результат и не меняют контекст запуска. Сохранённые данные проверяются до commit; уже выполненный durable commit остаётся отдельным состоянием.
- Manager обновляет состояние процесса при изменениях metadata от MCP, сохраняя состояние остальных профилей. Неизменённый список и правки только папок не запускают повторный scan.
- MCP получил `template_list` и применение сохранённого шаблона через `templateID` в `profile_create`: новая identity, безопасные настройки, теги и папка; без копирования cookies, заметок и паролей. Всего 18 инструментов управления и 7 чтения. Старые подключения только для чтения сохраняют свои права.
- Справка MCP объясняет подключение в три шага; редактор поясняет стартовую страницу и `about:blank`. На главной browser.free опубликованы практические примеры для вебмастера и рекламных проектов, FAQ об оплате, прокси, данных и возможностях AI.
- Проверка публичной Git-истории отклоняет неполный shallow checkout и учитывает все исторические имена, включая удалённый `.env` с повторно использованным blob. CI получает полную историю и сверяет документацию MCP с фактическими инструментами.
- Уточнены ограничения: снимок настроек не восстанавливает BrowserData; session cookies могут исчезать при закрытии; внешний AI-клиент может отправлять metadata своей модели; управление страницами и authenticated SOCKS5 в production не добавлены. Safe Browsing остаётся отключённым, полная аппаратная production-квалификация открыта.

## Direct 0.7.24 (87) — public alpha

Версия использует Chromium 156.0.8078.12 ARM64 Metal. Исходники, toolchain, выполненная сборка и payload связаны проверяемыми receipts. Exact headed, notarization, Gatekeeper и hosted gates должны завершиться до публикации. Это public alpha; глобальное обновление 1.0.0 ещё не завершено.

- Повреждённый файл папок больше не блокирует исправные профили после фонового обновления. Последнее состояние папок сохраняется, их изменение остаётся запрещённым до восстановления.
- Ожидание metadata guard ограничено 50 мс: долгий чужой commit не замораживает синхронный UI/MCP. Краткие записи локального журнала успевают завершиться; при занятости нужно перечитать состояние и повторить действие.
- IP-ответ с явным error:true не принимается как успешный контекст прокси. Некорректный первый ответ больше не перекрывается резервным источником после отказа второго сервиса. Сбой IP-сервиса и отказ прокси остаются разными результатами.
- В узкой справке подпись доступа MCP больше не сжимается по буквам. Disposable Dev root сохраняется в тестовом пакете и при повторном открытии без environment; production игнорирует этот ключ.
- Справка MCP уточняет 6 инструментов чтения / 17 управления; примеры сайта используют стандартный каталог и объясняют выбор workspace.
- Проверка секретов больше не пропускает большие Git blobs. CI включает все восемь ранее пропущенных наборов тестов; manager test/build helpers используют native SwiftPM и два jobs.
- Новый M156 runtime исправляет семантику Canvas/Audio/WebGL и согласованность HTTP/JS identity; подробные ограничения квалификации сохраняются в release evidence. Safe Browsing остаётся отключённым; authenticated SOCKS5 relay не включён в production. Совместимость всех Mac и сторонних AI-клиентов не заявляется.
- Импорт закладок создаёт отдельный профиль с новой identity; безопасная очистка кэша доступна только при подтверждённом закрытом профиле и сохраняет cookies/IndexedDB/расширения.
- CRX3 проверяется криптографически; отсутствие корректной подписи не обозначается verified.
- Разрабатываемые encrypted BrowserData backup, relay и atomic updater не включены в production: их локальные тесты не заменяют полный пользовательский release gate.

- MCP: новая настройка подключения включает полное текущее управление профилями; только просмотр доступен дополнительно. Старые настройки без разрешающего флага остаются только для чтения.
- MCP: повреждённый файл папок больше не блокирует статус и штатную остановку своего браузера; повреждённая primary metadata по-прежнему закрывает операции.
- Browser.free снова предлагает последний реально опубликованный ZIP/DMG независимо от готовности следующего runtime. Источник URL ограничен точным GitHub repository/tag/asset.

## Direct 0.7.23 (86) — 7 октября 2026

- MCP поддерживает современный 2026-07-28 через metadata каждого запроса и server/discover, сохраняя 2025-11-25/2025-06-18 handshake. Исправлены malformed initialized и ответы после принятой cancellation.
- 17 инструментов: новый workspace_query_profiles ищет по имени, тегам, проектам, закреплению и архиву; заметки исключены. Cursor связан с metadata и фильтром.
- Папки читаются страницами; изменения возвращают компактный receipt. Лимит учитывает text и structuredContent вместе, включая современный resultType.
- Все management-инструменты получили outputSchema; ошибки — стабильный код и следующий шаг. Три MCP prompts предлагают безопасные workflows без выполнения операций.
- Встроенная справка генерирует настройки семи клиентов: Claude Desktop/Code, ChatGPT Desktop/Codex, Grok CLI, Cursor, VS Code/Copilot, Gemini CLI. Web-транспорт и документационная совместимость описаны отдельно.
- Обновлены MCP cookbook, FAQ и browser.free: традиционный антидетект с дополнительным управлением профилями через AI.
- Chromium 154.0.8037.98 сохранён. Safe Browsing остаётся отключённым. Физический VoiceOver/сторонние AI-клиенты не квалифицированы.

## Direct 0.7.22 (85) — 7 октября 2026

- 16 MCP-инструментов управления профилями, прокси, папками, metadata и штатным запуском/остановкой. Read-only по умолчанию; управление включается явно.
- UUID/revision checks, Keychain и process ownership; GUI обновляет внешние metadata, сохраняя черновики.
- 731 Swift/82 suites, 29 privacy, 27 Site tests; реальный Dev/stdIO, cookies/LS/IDB persistence/isolation, cancellation/EOF/reconnect и keyboard. Direct signing/notary/stapling/Gatekeeper и hosted ZIP/DMG проверены.
- Chromium 154.0.8037.98 без пересборки. Ограничения: session-owned stop, нет DOM/JS/shell, удаления BrowserData, полного backup или remote bridge.

## Direct 0.7.21 (84) — 7 октября 2026

- Встроенная локальная справка с поиском по восьми темам; контекстные кнопки в редакторе, среде и библиотеке, без сброса черновика.
- Готовые настройки MCP для текущего executable и фактического workspace: JSON для Claude Desktop, TOML для Codex; примеры запросов и устранение ошибок.
- MCP отклоняет null/дробные ID и неполную инициализацию. Добавлены read-only annotations, outputSchema и structuredContent с общим ограничением размера. Два инструмента чтения; создание/запуск и web-мост не реализованы.
- Исправлено пояснение о хранении пароля прокси, понятнее диагностика, шаблоны и фильтры. Синхронизированы RU/EN инструкции и название снимка настроек.
- Прошли 720 Swift-проверок, реальный Dev.app smoke, поиск с клавиатуры, сохранность черновика после справки, copied-config stdio и запуск/остановка профиля с открытой справкой.
- Chromium 154.0.8037.98 не пересобирался. Физический проход VoiceOver не заявляется проверенным. Safe Browsing остаётся отключённым.

## Direct 0.7.20 (83) — 7 октября 2026

- Исправлено чтение старых профилей с `about:blank`. Старые Dev-данные проверены без изменения файлов; отдельно подготовлен заполненный синтетический стенд.
- Неизвестные схемы хранения отклоняются до чтения содержимого; более новый файл папок не заменяется старой резервной копией. Перемещение и metadata Undo блокируются во время импорта.
- Запуск перепроверяет сохранённую ревизию, прокси, identity, архивирование и стартовую страницу: устаревшее значение из другого окна не выбирает сетевой маршрут.
- Исправлены передача больших данных дочернему процессу и отмена подготовки прокси. Неполные сведения о маршруте не обозначаются готовой средой.
- Редактор сохраняет исходный черновик и его ID при обновлениях SwiftUI. В Dev.app проверены возврат имени без ложного предупреждения и защита несохранённой строки прокси. В быстрых командах добавлено явное открытие через кнопку и Cmd+Return; обычный Return выбирает профиль в manager.
- Убрано скрытие интерактивных окон и подсказок от macOS accessibility tree; физическая проверка всех вложенных диалогов ещё не завершена. Read-only MCP получил страницы с проверкой ревизии и ограничением ответа, без конфиденциальных полей.
- Для загрузки сохраняются независимые ZIP/DMG с проверкой байтов; recovery journal остаётся нетронутым.
- Прошли 715 Swift, 45 Python и 4 snapshot-проверки; отдельные сценарии запуска, persistent storage, контролируемого сбоя и локального HTTP-прокси проверены на прежнем Chromium 154.0.8037.98 без пересборки.
- Выпуск опубликован после проверки форм, клавиатуры, привязки кандидата и скачанных байтов; ограничения GUI перечислены в delivery evidence. Физический проход VoiceOver не заявляется проверенным. Safe Browsing остаётся отключённым.

## Direct 0.7.19 (82) — 7 октября 2026

- Карточка профиля стала читабельнее: увеличены основные подписи, а состояние профиля, прокси и действия сгруппированы по важности.
- Подробная диагностика среды остаётся доступной по раскрытию; основной сценарий запуска больше не требует просматривать все технические поля.
- Добавлены проверки компоновки на узком окне и с длинным содержимым. Профили пользователя и встроенный Chromium 154.0.8037.98 не изменялись.

## Direct 0.7.16 (79) — 5 октября 2026

- Проверка прокси больше не зависит от одного IP-сервиса: два независимых ответа сверяются по выходному IP, стране и часовому поясу; язык берётся из проверенного ответа. При недоступности сервиса остаётся резервный источник. Противоречивые ответы не засчитываются как успех.
- Ошибка или лимит IP-сервиса показывается отдельно от неисправности прокси. Проверка не обещает маршрут Chromium: он подтверждается отдельно.
- В форме явно показаны тип и порт прокси, варианты вставки строки и результат проверки; узкое окно отдаёт редактору всю основную область.
- Тесты: 682 Swift-проверки, живой прогон 33 выборочных HTTP-прокси через два сервиса и авторизованный маршрут на существующем Chromium 154.0.8037.93. Пользовательские профили в этом прогоне не менялись.

## Direct 0.7.15 (78) — 5 октября 2026

- Исправлено чтение сохранённого формата профилей версии 1 и его резервной копии: существующие профили больше не выглядят пустым списком после обновления.
- При недоступных данных создание профиля заблокировано с понятным сообщением; сохранённые файлы не заменяются пустыми.
- Создание профиля доступно явной кнопкой в списке и в пустом состоянии; прямой запуск без прокси назван отдельно. Форма настройки открывается в правой области окна с постоянно видимыми действиями.
- Добавлены regression tests для восстановления, неподдерживаемой схемы и формата прокси с авторизацией. Локальный импорт и проверка маршрута Chromium различаются в диагностике.
- Chromium 154.0.8037.93 сохранён без пересборки; это обновление manager.

## Direct 0.7.14 (77) — 4 октября 2026

- Исправлена согласованность `navigator.deviceMemory` и HTTP Client Hints на навигации и запросах из страницы в том же Chromium 154.0.8037.93.
- Подпись manager сохраняет App ID для Keychain и больше не заявляет лишний Team ID, который мог блокировать запуск через AMFI.
- Release gate проверяет оба пути Device Memory на локальном fixture и требует связанное runtime evidence; пользовательские профили не используются.

## Direct 0.7.13 (76) — 3 октября 2026

- Исправлена штатная остановка browser: graceful quit сохраняет буферизованные persistent data; отказ не приводит к принудительному завершению.
- Быстрые команды, пользовательские безопасные шаблоны, сохранённые фильтры, revision-safe metadata Undo и локальный ограниченный журнал.
- Ограничена подготовка запусков; memory pressure/thermal warning блокируют новые старты, не останавливая работающие профили.
- Chromium 154.0.8037.93 сохранён без пересборки. ZIP/DMG прошли Direct gates и fresh hosted hashes.
- G/H и batch UI отложены; session cookies и полный session backup не обещаются. Подробные ограничения: releases/v0.7.13.json.

## Direct 0.7.12 (75) — 2 октября 2026

- Chromium пересобран и обновлён до 154.0.8037.93 для Apple Silicon / Metal.
- Исправлены обработка лимита размера профиля и согласованность импорта; preview прокси выполняется в фоне и отклоняет устаревший ввод.
- Из упаковки менеджера убраны пути локального Swift/Metal toolchain; проверка приватности выполняется до отправки Apple.
- Речевые объявления приложения убраны; Tab и горячие клавиши сохранены. Физический проход клавиатуры/VoiceOver не заявляется проверенным.
- ZIP/DMG подписаны, notarized, stapled, приняты Gatekeeper и проверены после скачивания с GitHub. На browser.free открыты прямые загрузки.
- Safe Browsing остаётся отключённым; защита Google Safe Browsing не предоставляется.
- Rollback: неизменяемый v0.7.11.

## Direct 0.7.11 (74) — 24 сентября 2026

- В предварительном просмотре восстановления VoiceOver теперь получает
  отдельное имя сводки и произносит число добавляемых профилей и изменения
  папок одной понятной фразой.
- Действия озвучиваются с контекстом: отмена закрывает просмотр без изменений,
  подтверждение добавляет профили из снимка.
- Keyboard Return/Escape, безопасная отмена, повторная проверка активных
  профилей и транзакционное восстановление сохранены.
- Добавлены проверки accessibility summary и приватности. Физический
  VoiceOver проход ими не подтверждается.
- Chromium 153.0.8010.52 / Metal сохранён без пересборки.

## Direct 0.7.10 (73) — 24 сентября 2026

- Перед восстановлением snapshot показывается его дата, количество профилей и
  aggregate-сводка папок. В preview нет имён профилей, заметок, proxy-данных
  или identity values.
- Восстановление выполняется только после явного подтверждения; отмена не
  меняет хранилище. Подготовленный и проверенный payload используется для
  commit без повторного чтения snapshot, а guard работающих профилей
  перепроверяется непосредственно перед транзакцией.
- Preview поддерживает Return/Escape, VoiceOver labels и подсказки; добавлены
  privacy/unit и responsive-render regression tests. Физический VoiceOver
  acceptance отдельно не подтверждён автоматическими тестами.
- Chromium 153.0.8010.52 / Metal сохраняется; Chromium не пересобирается.

## Direct 0.7.9 (72) — 24 сентября 2026

- New-profile quick-start offers editable «Работа» and «Тестирование» templates;
  they prefill only a suggested name and tag and leave runtime settings alone.
- Profile diagnostics can show a 24-hour, exact-profile/runtime-bound summary
  of observed browser feature availability. It explicitly does not claim that a
  particular site works or that its login/business flows were tested.
- `scripts/neantik-release-evidence-summary.py` prints a local read-only release
  gate summary, separating historical release records from current candidate
  evidence without reading credentials or raw fingerprint reports.
- Snapshot save/restore and plain/encrypted profile export prepare data off the
  UI thread; restore rechecks running profiles before its atomic commit.
- Diagnostics retains a compact, read-only recovery notice for the current
  app session after profile or folder metadata is recovered. It remains
  visible with no selected profile, including an empty workspace.
- Closing the workspace cancels in-flight profile import, export, and snapshot
  tasks before any pending restore commit.
- Plain and encrypted export files are written atomically off the UI thread.
- Cancelling import validation remains a cancellation state, not a corrupt-file
  error.
- Snapshot completion says how many stopped profiles were saved and how many
  running profiles were skipped.
- Export/import copy explicitly states that proxy login is included, while
  proxy passwords, BrowserData, cookies, notes, identity seeds and Keychain
  secrets are not.
- Snapshot read failures do not expose local paths in the UI.
- Chromium 153.0.8010.52 is retained unchanged; this is a manager-only release,
  not a Chromium security update. Publication still requires exact-candidate
  Developer ID, notarization, Gatekeeper, hosted-asset and live-site gates.

## Direct 0.7.8 (71) — 24 сентября 2026

- Подсчёт объёма BrowserData выполняется отменяемой фоновой задачей; интерфейс
  показывает состояние подсчёта и не блокируется обходом файлов.
- Импорт конфигураций читает, проверяет и расшифровывает файл в фоне; атомарная
  запись профилей остаётся под контролем хранилища.
- Давность проверки прокси видна в профиле; старый результат, последний сбой
  и изменившиеся настройки не обозначаются свежей успешной проверкой.
- Защищённое помещение файла в карантин отклоняет symlink-путь к данным вне
  профиля; добавлен bounded corpus отказов для повреждённого импорта.
- Chromium 153.0.8010.52 сохранён. Это manager-only релиз, не обновление
  Chromium и не security update ядра.

## Direct 0.7.7 (70) — 24 сентября 2026

- Исправлены ложные предупреждения диагностики: собственный запущенный
  профиль не считается занятым другим процессом, архив успешного
  восстановления не требует повторного восстановления всех профилей.
- VoiceOver произносит конкретный следующий шаг диагностики.
- Панель медиа явно обозначает временное тестовое окружение.
- Chromium 153.0.8010.52 сохранён без пересборки. Это manager-only обновление,
  не обновление безопасности Chromium.

## Direct 0.7.6 (69) — 24 сентября 2026

- Диагностика профиля теперь сразу объясняет следующее безопасное действие
  для состояний «Требует внимания» и «Проверка недоступна», а готовый профиль
  остаётся без лишнего текста. В UI не добавляются raw paths, PID, IP, device
  IDs или fingerprint values.
- Добавлен глобальный продуктовый план 2026 с актуальной матрицей done/next/
  runtime-gate/defer и отдельными границами для Chromium rebuild, cloud,
  automation и anti-fraud bypass.

- Manager-only обновление diagnostics next-step UX на проверенном Chromium
  `153.0.8010.52`; ядро браузера не пересобиралось и не заменялось.
- Публичные ZIP и DMG прошли Developer ID, notarization, stapling,
  Gatekeeper и fresh-download gates.

## Direct 0.7.5 (68) — release candidate

- Менеджер получил завершённый pass по lifecycle health, безопасному импорту
  и экспорту, metadata-only snapshots, privacy-safe diagnostics/support bundle,
  quarantine/provenance и manager performance budgets.
- Обычный UI сохраняет короткий сценарий профиля; A → B → A остаётся явной
  release-only проверкой и не запускается скрыто при обычном старте.
- Исправлена release-проверка source contract: она теперь выбирает контракт
  Chromium 153 по фактическому runtime lock, а не ошибочно требует старый
  Chromium 152.
- Runtime Chromium `153.0.8010.52` не пересобирался и не заменялся.

- Release hygiene теперь учитывает канонические markdown-записи публичных
  релизов и разрешает версию исходников ниже публичного floor только при
  явной bilingual-пометке development preview; это не меняет бинарный
  runtime и не открывает путь к публикации неподтверждённого кандидата.
- Исторические `.command`-обёртки релиза `0.3.12` переведены в явный
  fail-closed режим; актуальные операции используют version-neutral entrypoint
  и не могут случайно обратиться к старому публичному DMG.
- Отдельный DMG release-flow теперь повторно проверяет публичный version/build
  floor перед любыми signing и notarization-действиями, даже если ZIP уже был
  подготовлен предыдущей фазой.
- Read-only Direct preflight теперь показывает тот же публичный version/build
  floor отдельным gate и не может выглядеть готовым при кандидате ниже
  последнего опубликованного релиза.
- Ошибки AffPapa release-client больше не выводят абсолютные пути к deploy
  credential или pinned known_hosts; приватные пути редактируются даже при
  неготовом окружении доступа.
- Ошибки запуска браузера, восстановления proxy-состояния и отката профиля
  больше не выводят абсолютные пути или системные детали; в приватной
  диагностике сохраняются только ограниченные категории событий.

## Direct 0.7.4 (67) — September 23, 2026

- Публичный Direct public-alpha релиз с Chromium `153.0.8010.52`, ARM64 и
  Metal; manager и runtime прошли подпись, notarization, stapling, Gatekeeper
  и повторную проверку опубликованного ZIP.
- Manager/UI pass и последующие verifier-изменения переходят в кандидата
  `0.7.5 (68)` и не смешиваются с уже опубликованным бинарным архивом.

## Direct 0.3.20 (23) — August 29, 2026

- Встроенный движок перенесён на Chromium 152.0.7977.64 из официального
  macOS Stable-релиза от 25 августа 2026 года. Source contract, toolchain,
  upstream/owned patches и postimage evidence обновлены для новой
  ARM64/Metal-сборки; старый Chromium 151 runtime не переиспользуется.
- Добавлен нативный однооконный workspace: первый профиль создаётся и
  открывается одним действием, а основные команды используют единое состояние.
- Добавлены одноуровневые папки, стабильные цветовые теги, локальные заметки,
  поиск по ним и безопасное дублирование с пустой заметкой клона.
- Массовое создание профилей сведено к локальному сценарию «вставить список
  прокси → проверить предпросмотр → создать» без скрытых сетевых запросов.
- Ручная проверка прокси остаётся добровольной диагностикой; перед каждым
  запуском прокси-профиля NeAntik заново подготавливает актуальный маршрут.
- Техническое состояние fingerprint, WebRTC, QUIC/DNS и геолокации доступно
  по запросу и не перегружает основной сценарий запуска.
- Добавлены immutable workspace snapshot и ограниченный read-only DTO для
  будущих локальных адаптеров; сетевой API и write-методы не включены.
- Весь persisted профиль теперь проходит единый fail-closed validator с
  ограничениями не только по символам, но и по UTF-8 bytes; ProfileStore,
  массовый импорт и история proxy-health используют общий лимит 10 000
  профилей без частичных каталогов или записей Связки ключей при отказе.
- История проверки прокси больше не может записать файл, который сама не
  способна прочитать: лимит 4 МиБ проверяется до atomic replace, а удалённые
  и устаревшие записи физически очищаются при загрузке workspace.
- Первое действие «Создать и открыть» стало стандартным Return-действием
  macOS, а строка «Дополнительно» в редакторе нажимается целиком и имеет
  явные VoiceOver label, value и hint.
- Manager-only packaging сохраняет русские bundle-ресурсы и проверяет их
  перед выпуском; release build теперь явно закреплён за ARM64.

## Direct 0.3.19 (22) — August 14, 2026

- Исправлена боковая панель в пустом состоянии: заголовок, создание профиля
  и управление sidebar теперь всегда закреплены сверху, а пустое состояние
  занимает только оставшуюся область окна.
- Кнопки скрытия sidebar и создания профиля получили одинаковую фиксированную
  геометрию 32×32. Системный индикатор меню больше не сдвигает и не обрезает
  значок «+» при любом разрешённом размере окна.
- Поиск скрыт, пока профилей нет, потому что в этом состоянии он ничего не
  фильтрует. После удаления последнего профиля старые поиск и фильтры безопасно
  сбрасываются.
- Добавлены нативные render-регрессии для пустого и заполненного sidebar на
  минимальном и широком окне.
- Встроенный Chromium остаётся на проверенной версии 151.0.7922.108; тяжёлая
  пересборка runtime для этого интерфейсного выпуска не выполняется.

## Direct 0.3.18 (21) — August 14, 2026

- Обычный интерфейс окончательно отделён от служебной проверки отпечатков:
  пользователь видит только создание профиля, необязательный прокси и запуск,
  а автоматическая A → B → A проверка остаётся закрытым fail-closed этапом
  выпуска.
- Постоянные технические статусы и параметры отпечатка убраны с главного
  экрана. Подготовка данных профиля больше не называется «проверкой», чтобы не
  путать её с release-аудитом.
- Новые профили по умолчанию открывают изменяемую страницу
  `https://aff.top/tools/fingerprint`. Сохранённые стартовые страницы старых
  профилей и дубликатов не переписываются.
- Телеметрия самого NeAntik по-прежнему выключена.

## Direct 0.3.17 (20) — August 12, 2026

- Встроенный движок обновлён до Chromium 151.0.7922.108 — воспроизводимого
  macOS security baseline из официального Stable-релиза с 41 исправлением
  безопасности. Свежая ARM64/Metal-сборка прошла source provenance и полный
  Direct release gate.

- Обычный сценарий сокращён до «профиль → прокси при необходимости →
  запуск». Техническая проверка A → B → A больше не показывается пользователю
  и остаётся только в защищённом release gate.
- Вставка прокси теперь выполняется мгновенно и локально; внешняя проверка
  соединения запускается только отдельной необязательной кнопкой. Устаревший
  результат старой проверки больше не блокирует запуск и не передаёт
  Chromium неподтверждённые timezone/locale.
- Главная панель оставляет запуск и изменение на виду, а данные, архив,
  дублирование и удаление собраны в компактном меню «Ещё».
- Главный экран показывает обычному пользователю только стартовую страницу,
  состояние изоляции и сеть. Полный путь BrowserData, часовой пояс и
  технические параметры перенесены в сворачиваемый блок «Технические
  сведения».
- Добавлены закрепление, архив без удаления BrowserData и безопасное
  дублирование профиля с новым UUID, новым fingerprint seed и отдельной
  папкой. Настройка прокси и её пароль тоже копируются; пароль остаётся только
  в Связке ключей.
- Добавлено массовое создание до 100 независимых профилей из списка прокси.
  Форматы распознаются локально, соединения автоматически не проверяются, а
  при ошибке профили не сохраняются. Даже при редком повторном сбое Связки
  ключей осиротевший секрет помечается для безопасной одноразовой очистки при
  следующем запуске.
- Архивный профиль нельзя запустить ни из интерфейса, ни прямым вызовом
  менеджера процессов; сначала его нужно вернуть из архива.
- Добавлены migration, process, Keychain rollback, responsive layout и
  privacy regression-тесты для нового сценария.

## Direct 0.3.16 (19) — August 6, 2026

- Встроенный движок обновлён до Chromium 151.0.7922.75 для Apple Silicon.
  Исходники, macOS-патчи и toolchains закреплены проверяемыми hashes; runtime
  по-прежнему собирается только для arm64 с Metal.
- Приватные seed и timezone-контекст профиля удалены из аргументов процессов.
  Менеджер передаёт Chromium только минимальный allowlist системных переменных
  и проверенную конфигурацию: proxy environment, TLS key logs и посторонние
  токены из Terminal не наследуются. Release gate отдельно запрещает возврат
  старых argv-маркеров. Каждый процесс валидирует seed один раз, поэтому
  Canvas/WebGL/Audio больше не повторяют чтение окружения в горячих циклах.
- Исправлена защита WebRTC-маршрута: менеджер теперь использует
  `--webrtc-ip-handling-policy`, который shipping Chromium действительно
  связывает с профильной политикой. Ранее применялся похожий switch для
  content shell/headless; отдельный source-gate не позволит вернуть эту
  ошибку.
- Удалён давно не поддерживаемый `--dns-prefetch-disable`, а неточное имя
  feature `DnsOverHttps` заменено на реальное для Chromium 151
  `DnsOverHttpsUpgrade`. Новый source-gate привязывает proxy, DNS, QUIC,
  WebRTC и WebGPU controls к точным исходникам движка, чтобы неработающий
  флаг больше не считался защитой.
- Удалён исчезнувший в Chromium 151 `--disable-background-mode`, чтобы
  интерфейс не создавал ложного ощущения работающего ограничения.
- Удалён несуществующий Chromium switch `--timezone=...`. Часовой пояс
  профиля теперь передаётся только через закрытый и валидируемый
  `NEANTIK_PROFILE_TIMEZONE`; пользовательские дополнительные аргументы
  по-прежнему не могут подменить этот контракт.
- Public-alpha проверка больше не принимает частичный fingerprint PASS:
  обязательны прямой WebRTC positive-control, отсутствие прямых кандидатов
  при прокси, согласие page и worker, locale/Client Hints и целостный Apple
  Silicon tuple. Расширенные повторные поверхности остаются отдельным
  честным production-gate.
- Усилен контроль собственных Chromium-патчей: частично применённый или
  изменённый patchset теперь блокирует сборку, а уже применённый принимается
  только при точном совпадении всех итоговых postimage.
- Активный branding-патч в открытом manifest переименован в NeAntik, а
  устаревшие Chromium 150 TODO-заглушки удалены: опубликованный исходный код
  больше не выглядит как незавершённый перенос старого NeVision.
- Воспроизводимая сборка Chromium сама устанавливает закреплённый Dawn Go
  toolchain и хранит Go/Python-кэши внутри build-root. Из shipping-графа убран
  неиспользуемый `chromedriver`, поэтому повторная сборка не выполняет лишнюю
  работу. Каждая попытка получает чистый короткий build-log, а предыдущий лог
  сохраняется отдельно — старые ошибки больше не смешиваются с текущим
  результатом.
- Публично зафиксировано ограничение privacy-oriented runtime: Google Safe
  Browsing не включён, поэтому изоляция профиля не заменяет защиту от фишинга,
  вредоносных сайтов и опасных загрузок.
- Главный экран переведён с `NavigationSplitView` и unified toolbar на
  собственную нативную двухпанельную оболочку. Минимальный размер окна
  зафиксирован на 820×560, sidebar занимает 240–300 px и может быть скрыт или
  возвращён одной кнопкой.
- Заголовок, поиск, создание профиля и список находятся в фиксированной шапке
  sidebar ниже системных traffic lights. Они больше не участвуют в прокрутке
  и не могут уехать под titlebar.
- Иконка, название, состояние и все пять основных действий профиля закреплены
  над отдельно прокручиваемыми сведениями. На узком окне кнопки образуют
  компактные строки, на широком — один ряд; сохранённая позиция прокрутки
  больше не может спрятать запуск, изменение, данные, проверку или удаление.
- Убрано дублирование названия и состояния профиля между системным titlebar и
  карточкой. Широкое окно использует ограниченную читаемую ширину содержимого
  с выравниванием влево вместо маленького острова по центру.
- Исправлена строка «Дополнительно» при создании профиля: она раскрывается
  явной кнопкой, а иконки, цвета и сетевые поля адаптируются к узкому окну.
- В редактор добавлена безопасная вставка и явная проверка прокси в форматах
  `login:password@ip:port`, `ip:port@login:password`,
  `login:password:ip:port` и `ip:port:login:password`. Пароль не попадает в
  профиль, логи или сообщения и хранится только в Связке ключей.
- Обычная проверка профиля направляет клавиатурный фокус на главное действие,
  а сравнение профилей и нижние кнопки имеют компактную раскладку для узкого
  окна.
- VoiceOver теперь объявляет начало и итог проверки профиля, а также успех
  или ошибку вставки и проверки прокси; кнопка возврата sidebar получила
  явную accessibility-метку и в пустом состоянии.
- Добавлен `Develop-NeAntik.command`: тёплая UI-пересборка заменяет только
  Swift-менеджер в отдельной `NeAntik Dev.app`, не трогает публичные профили,
  `dist`, fingerprint evidence, notarization, GitHub или сайт.
- Исправлен запуск `Develop-NeAntik.command` двойным кликом: SwiftPM всегда
  запускается из каталога проекта, даже если Terminal открыл команду из
  домашней папки. Dev.app запускается напрямую в пользовательской Terminal-
  сессии и не зависит от нестабильного кэша Launch Services.
- Единый Direct release больше не переиспользует ZIP или DMG только по имени:
  каждый выпуск создаёт оба файла заново из одного точного кандидата.
  Повторный запуск не упирается в старые файлы: предыдущий локальный комплект
  переносится в закрытый каталог попытки и остаётся доступен для диагностики.
  GitHub и AffPapa публикуются двухфазно: сначала неизменяемые файлы,
  затем полная повторная загрузка и проверка, и только после этого атомарно
  переключаются `release.json` и страница. Любая ошибка после переключения
  запускает серверный rollback.

## Direct 0.3.15 (18) — August 4, 2026

- Direct-менеджер теперь запускает только встроенный `NeAntik Browser`.
  Сохранённый старой версией путь к Chrome, Chromium или другому runtime
  игнорируется; ручной выбор и ручное объявление fingerprint-режима удалены
  из публичного интерфейса. Отсутствующий или повреждённый встроенный движок
  блокирует запуск с понятным сообщением.
- Поиск и фильтр больше не оставляют скрытый профиль активным в карточке:
  выбор автоматически переходит на первый видимый профиль или очищается.
- Для уже существующего корректного `profiles.json` при первом запуске
  создаётся закрытая recovery-копия, даже если пользователь ещё не изменял
  профиль. BrowserData, cookies и данные сайтов при этом не переписываются.
- Создание профиля упрощено до названия и необязательного прокси. Стартовая
  страница, иконка, цвет и теги остаются доступны в раскрываемом блоке
  «Дополнительно»; новый профиль сразу получает фокус в поле названия.
- При невозможности проверки профиля интерфейс теперь постоянно показывает
  причину, а не прячет её только во всплывающей подсказке.
- Символы профилей автоматически используют чёрный или белый цвет с
  достаточным контрастом на выбранном фоне; добавлен regression-test палитры.
- Обычный запуск больше не вычисляет SHA-256 243-МБ Chromium Framework.
  Полные hashes остаются обязательными для A → B → A и release evidence.
- Проверка встроенного runtime ищет девять обязательных Chromium-маркеров за
  один потоковый проход. Измеренное время `verify-built-runtime.sh`
  уменьшилось примерно с 23,4 до 3,7 секунды без ослабления fail-closed gate.
- Исправлена изоляция тестов GUI-readiness: временный project root больше не
  читает существующий `dist/fingerprint-audit.json` из рабочего проекта.
- Release-команды отвязаны от номера версии. Постоянные
  `Release-NeAntik.command`, `Run-NeAntik-Release.command` и hosted-verifiers
  читают version/build из `Info.plist`, поэтому для следующего выпуска не
  нужно копировать четыре новых скрипта.

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
