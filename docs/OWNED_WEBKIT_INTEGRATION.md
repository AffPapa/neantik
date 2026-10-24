> Текущий source-статус на 21 октября 2026: manager/child/broker lifecycle
> подключён. Pinned host сообщает manager точную session generation при выходе;
> устаревшее поколение игнорируется, выход во время запуска обрабатывает путь
> отката запуска, неожиданный выход активной сессии сначала отзывает только её
> broker scope и освобождает process fence лишь после подтверждённого завершения
> child. При неудачной очистке профиль остаётся занятым, BrowserData не удаляется.
> Это реализовано в текущем dirty checkout, но не подтверждено process-crash
> испытанием на точном подписанном runtime. Актуальные manager/host SHA прошли
> полный source regression: 1796 тестов / 221 suite, jobs=2, плюс 42 Python
> контракта. См. [current-source receipt](evidence/webkit-current-lifecycle-regression-20261021.json).
> Исторический receipt
> [`webkit-unexpected-exit-cleanup-20261020.json`](evidence/webkit-unexpected-exit-cleanup-20261020.json)
> относится к прежним SHA и не используется для текущих файлов. Точный owned WebKit proxy остаётся выключен:
> headed NetworkProcess A/B, no-Direct, DNS/TLS и отказ/восстановление не прошли.
> Более ранние разделы ниже — исторические снимки; использовать их только вместе
> с датированными receipts, не как текущее описание.

# Защищённый WebKit: интеграция

Статус: разработка. В публичной 0.8.26 прокси WebKit выключен.
Исследовательский runtime и работающий внутренний компонент не заменяют
проверку поставляемого приложения.

Системный `WKWebView` не должен объявлять или запускать proxy ни в Dev, ни в
Release: этот код не обеспечивает требуемую изоляцию, а исследования обнаружили
Direct для private IPv4. Настройка профиля сохраняется; открытие такого профиля
fail-closed до включения отдельного проверенного runtime.

## Что уже реализовано

Метаданные получили явное поколение persistent WebKit store: `system` или
`isolatedV1`. Поколение неизменяемо при редактировании, входит в снимок
запуска и clone/metadata-transfer; его наличие поднимает профильный envelope до
версии 5, portable transfer — до версии 4. Старые версии должны отвергать
такой envelope. `isolatedV1` пока нельзя запустить: manager откажет до открытия
данных, пока подписанный helper и runtime не встроены и не квалифицированы.

## PID bridge: source-tested, not runtime-qualified

Закреплённый owned WebKit экспортирует C API
`WKWebsiteDataStoreGetNetworkProcessIdentifier`; эта функция присутствует и в
отдельном staged `WebKit.framework` (SHA-256
`dc734a42f164b143a1b92d1cb0de278a82a65e86d0f8839970c54f4b89eddf7f`). В NeAntik
добавлен resolver, который сначала подтверждает подписанный helper pin и
единственный загруженный WebKit image, затем ищет экспорт через handle этого
образа с `RTLD_NOLOAD`. Поиск через `RTLD_DEFAULT` и загрузка системного
WebKit запрещены. Набор `WebKitOwnedNetworkProcessPIDTests` вместе с
`WebKitRuntimeImageAttestationTests` прошёл 10/10 в одном jobs=2 запуске за
9.7 с ([receipt](../.build/neantik-local/test-receipts/20261019T233422Z-26696.json)).

Это проверяет fail-closed source contract и синтетическую C ABI-вызовку, но
ещё не вызов на реальном `WKWebsiteDataStore`, PID NetworkProcess или сетевой
маршрут. Resolver не подключён к manager/окну. Последний source-срез добавляет
host-facing `currentOwner`: PID плюс два совпавших kernel snapshot по start-time,
UID и наблюдаемому PPID. NetworkProcess поставляется как XPC-служба, поэтому
PPID не должен совпадать с host. Публичный `proc_bsdinfo` не предоставляет
`pidversion`; не использовать его как условие приёмки. Content filter не выбран
сетевой границей. Typed IPC owner frame связан с profile/session/revision и
принимается до запуска страницы. Текущий handshake устроен так: child
сообщает owner NetworkProcess → host проверяет живую подпись и выдаёт capability
точной сессии → child отправляет `ready`. Owner frame сам не аутентифицирует
peer; это остаётся обязанностью транспортного слоя. Live-code lease требует
подтверждения точной сессии при регистрации маршрута и выдаче capability.
Targeted IPC/lease suites прошли 13/13 ([receipt](../.build/neantik-local/test-receipts/20261020T041317Z-55807.json)).
Пока нет manager/host call site, который передаёт report через authenticated
IPC; закрытие профиля, изменение revision и смерть процесса ещё не связаны с
отзывом lease. Loopback-поведение broker и уже открытые потоки этим source-тестом
не проверялись. После подписания точного runtime нужно подключить этот lifecycle,
затем доказать sandbox-блокировку прямого выхода, proxy A, независимый Direct B,
relay loss/recovery и отзыв полномочий на двух временных профилях. Пока этот
путь не квалифицирован, WebKit proxy остаётся выключенным.

Следующий source-срез добавил `WebKitProxyConfigurationFactory`: он строит
конфигурацию Network.framework для HTTP CONNECT только к `127.0.0.1:45100`,
передаёт короткоживущую scoped broker capability, оставляет
`allowFailover = false` и не задаёт domain exceptions. Пароли upstream в эту
конфигурацию не входят. Набор прошёл 6/6 ([receipt](../.build/neantik-local/test-receipts/20261020T041734Z-56205.json)).
Это проверяет только factory contract: адаптер пока не передаёт конфигурацию в
`WKWebsiteDataStore`, не запускает WebKit и не доказывает блокировку Direct.
Следующий шаг — подключить factory к owned host вместе с отзывом capability
при закрытии/смене revision/завершении процесса; до точного подписанного A/B
WebKit proxy остаётся выключенным. Документация Apple описывает HTTP CONNECT
как TCP proxy; UDP/WebRTC этим путём не квалифицирован.

Следующий source-срез добавляет lease sweep в broker: раз в секунду live
NetworkProcess attestation перепроверяется вне listener queue; при потере
процесса/подписи broker отзывает capability и отменяет уже привязанные потоки.
Изменённые Swift файлы компилируются в targeted run. Тесты выбора истёкших
lease прошли 3/3; broker socket suite не смогла открыть loopback listener и
вернула `.unavailable` во всех пяти сценариях до проверки broker-поведения
([receipt](../.build/neantik-local/test-receipts/20261020T042213Z-56648.json)).
Это был setup-блокер ограниченного запуска, не результат проверок broker. После
получения точного elevated-контекста тот же `WebKitLoopbackBrokerTests` прошёл
5/5 без изменения исходников ([receipt](../.build/neantik-local/test-receipts/20261020T043604Z-57928.json)). Проверки остаются локальными synthetic socket tests; они не запускают WKWebView и не доказывают сетевую изоляцию NetworkProcess. Теперь следующий кодовый шаг — подключить owner/lease к manager/child lifecycle и explicit revoke; затем нужен exact signed-runtime A/B.

Последующий source-срез исправил порядок IPC handshake: owner report принимается
первым, capability выдаётся только после проверки scope profile/store/session/
revision, а `ready` принимается лишь после её выдачи. Credential связан с
исходной сессией и не может быть перекодирован для другой. IPC и lease suites
прошли 15/15 ([receipt](../.build/neantik-local/test-receipts/20261020T042801Z-57242.json)).
Это проверка state machine и сериализации; manager/host call site, peer
аутентификация на транспортном уровне и runtime не подключены. Proxy остаётся
выключенным.

Публичный релиз v0.8.25 отдельно сверен с source commit `796b44f80f814b294a972fe5ff1b5e3d6063e3f9`: `BrowserProcessManager.launchWebKitProfile` вызывает policy validation, а policy отвергает любой профиль с proxy до создания окна. GitHub API вернул опубликованный release с четырьмя notarized ARM64 assets; Sites API подтвердил активный browser.free Site154, связанный release manifest с 0.8.25/build137. Это подтверждает безопасный отказ в публичной версии, но не работающее прокси. См. [public boundary evidence](evidence/webkit-public-boundary-v0.8.25-20261020.json).

Для текущего системного WebKit проверен отдельный safety gate: `launchWebKitProfile`
вызывает `WebKitProfilePolicy.validate` до создания окна; `WebKitProxyFeature`
остаётся выключен, поэтому профиль с сохранённым proxy не запускается, а настройки
сохраняются. Совместимый ранее прогон `WebKitProfileTests` +
`WebKitProxyConfigurationFactoryTests` прошёл 21/21 (receipt
[20261019T191516Z-37266](../.build/neantik-local/test-receipts/20261019T191516Z-37266.json)).
Это блокирует запуск явно проксируемого системного WebKit по Direct, но не даёт
профилю работающий proxy и не является доказательством сетевой изоляции owned runtime.

## Совместимый runtime: исследовательский контроль

Для того же upstream commit `43d5b8d85e2e5eed41d7ff8a79da831bf405be6c`
изучен отдельный ARM64 архив с минимумом macOS 15.4. На macOS 27.0
зафиксированы headed A/B сетевые результаты: защищённый вариант передал запрос
аутентифицированному loopback relay, заблокировал private IPv4 Direct,
закрылся при отказе relay и восстановился; независимый Direct-контроль
оставался рабочим. Однако точный host и его подготовленная A-копия ссылаются
на системный WebKit абсолютным load command. Сохранённый `native-result.json`
не фиксирует путь или хеш реально загруженного framework. Поэтому A/B
подтверждает поведение этой сетевой схемы, но не доказывает, что был загружен
вложенный runtime 15.4; его нельзя считать квалификацией собственного ядра.
Намеренно неограничённая копия повторно показала Direct bypass. Процессы,
relay и origin завершены.

Это подтверждает только HTTP-поведение исследовательской сетевой схемы на
macOS 27.0, не принадлежность загруженного WebKit к архиву 15.4. Минимум 15.4
в Mach-O не доказывает ни путь загрузки, ни запуск на macOS 15.4. Не проверены в этой
матрице DNS-on-wire, HTTPS/TLS, IPv6, WebRTC, WebSocket, delegated/background
traffic, manager, persistent profile stores или MCP. Архив не notarized и
ещё не встроен в приложение. Подробные хеши и условия: [точный отчёт](evidence/webkit-compatible-runtime-15.4-attempt3.json).

`WebKitLoopbackBroker` резервирует один loopback endpoint, соответствующий
статической политике собственного runtime. `WebKitRelayAuthority` выдаёт
отдельный случайный ключ для сочетания profile/store/session/revision.
Ключ выбирает неизменяемый маршрут: явно выбранный Direct либо настроенный
upstream. Неизвестный ключ отклоняется до соединения с адресом назначения.
Host IPC теперь имеет отдельный frame для одноразового relay-ключа:
конструктор сверяет scope с profile/store/session/revision, а обычное debug- и
reflection-представление ключа скрыто. Это только проверенный IPC-контракт;
manager ещё не вызывает его после live-проверки parent/child и пока не отправляет ключ.

Отзыв удаляет полномочия до отмены соединений. Старый session/revision не
может отозвать новую сессию того же профиля. Остановка закрывает listener,
отзывает все ключи и дожидается завершения задач. Пароли upstream не передаются
странице и не возвращаются через MCP. HTTP/SOCKS5/TLS transport переиспользует
существующий код; жизненный цикл Chromium не изменён.

Проверены модель полномочий и настоящие loopback TCP-соединения: два профиля,
неверный ключ, отзыв, независимый профиль после отзыва, authenticated HTTP
upstream, его отказ, отдельный Direct-контроль и лимит соединений. Это тесты
компонента, без WKWebView, настоящих профилей или Keychain.

Ключ — bearer capability. Он не доказывает PID Apple helper или принадлежность
WK store. Регистрация допустима только после проверки подписанного контроллера,
дочернего процесса и снимка метаданных. Эти проверки ещё нужно подключить.

## Упаковка runtime теперь имеет проверяемый контракт (source-only)

Публичный `prepare-direct-runtime-candidate.sh` сейчас **отказывает** при
передаче `NEANTIK_OWNED_WEBKIT_HOST_BINARY` или
`NEANTIK_OWNED_WEBKIT_FRAMEWORKS` до начала сборки. Это не позволяет обойти
закрытый gate в `package-app.sh` и незаметно вложить непроверенный движок в
публичный кандидат. Интегрированный verifier при этом независимо проверяет
host pin и hash-bound notices, если вложенный host присутствует.

Для отдельной Dev-only QA-копии прежний pin mismatch исправляют после финальной
подписи host: `verify-webkit-host-pin.py --refresh-pin APP`, затем неглубокая
подпись manager и повторная pin-проверка. Это не разрешает включать owned runtime
в публичную сборку. Когда общие WebKit release gates будут закрыты, включение
runtime должно идти через штатный пакетировщик после снятия release guard и
обязательно сохранить этот порядок pin → подпись manager → итоговая проверка.

`package-webkit-host.py` принимает отдельный runtime-linked host либо точный
manager executable из целевого NeAntik.app, а также предварительно подписанный
каталог `Frameworks`. Для manager-варианта упаковщик создаёт временную копию и
меняет только в ней абсолютную ссылку на системный WebKit на bundle-relative
`@rpath`; исходный manager остаётся неизменным. Перед staging обычный режим проверяет Developer ID команды NeAntik; этот режим
используется для публичного релиза. Явный локальный `--recipient-relink` сначала
проверяет подпись manager.app и требует ту же Developer ID-команду у выбранной
identity и всех runtime images. Ad-hoc и смешанные команды не допускаются. Затем
упаковщик копирует runtime только во вложенный helper, проверяет подписи каждой
code bundle и Mach-O и требует одну ожидаемую команду у каждого образа. После
этого записывает SHA-256 именно `WebKit.framework/Versions/A/WebKit` в подписываемый
`NeAntikWebKitRuntimeV1` helper Info.plist. Любая ссылка из исходного дерева,
которая выходит за его границу, отклоняется; system-WebKit host по-прежнему
отклоняется до записи. Упаковщик также проверяет load commands каждого Mach-O
во входном дереве и отказывает, если вложенный WebKit/WebCore/JavaScriptCore/
WebGPU напрямую загружает соответствующий системный framework абсолютным
путём. Целевой package suite прошёл 21/21; проверка точного сохранённого layout
отказала на `TestWGSL`, как и должна. Это контракт и фиктивные Mach-O fixtures,
не квалификация runtime. Проверка абсолютных load commands не доказывает весь
`@rpath` closure или фактически загруженные образы. Upstream target graph
требует отдельные WebContent/Networking XPC службы и условный GPU service;
часть конфигураций использует Apple-private entitlements, а обычная upstream
ветка подписывает службы ad hoc. Сопоставление фиксированного production
target/install manifest с подписанным bundle остаётся открытым. См.
[`production target closure`](evidence/webkit-production-target-closure-20261020.json).
Отдельная статическая карта 13 выбранных framework/XPC Mach-O-кандидатов из
того же архива нашла прямые абсолютные system-engine load commands во всех
13. Поэтому тест уже не только говорит, что в архиве есть лишний `TestWGSL`:
сами предполагаемые поставляемые framework и XPC service binaries тоже не
являются relocatable runtime. [`точные load commands`](evidence/webkit-production-candidate-loads-20261020.json).
Полный статический проход layout нашёл 86 Mach-O файлов, включая тестовые утилиты; у 54 есть абсолютные ссылки на системные WebKit/JavaScriptCore/WebGPU компоненты. Это не production runtime closure. Исходные WebKit/WebCore/XPC также ссылаются на system WebKit; отдельный host `@rpath` этого не устраняет. Пока эта полная dependency closure не исправлена и не attested, архив нельзя вкладывать как изолированное ядро. См. [load-graph report](evidence/webkit-runtime-load-graph-20261020.json).

## Следующая законченная часть

1. Собственный runtime должен жить в отдельном подписанном helper-процессе.
   Упаковщик теперь может взять точный manager executable целевого NeAntik.app,
   создать временную копию, заменить только её системный WebKit load command на
   `@rpath` и добавить единственный путь
   `@executable_path/../Frameworks`; manager bytes остаются нетронутыми.
   Отдельный host, runtime Frameworks и их подписи всё ещё проверяются до
   staging. Package suite прошёл 25/25 с положительными и отрицательными
   контролями. Это проверка упаковочного контракта, не Developer ID сборка.
   Child entry point по-прежнему завершается fail-closed; manager spawn, WebView
   и сетевой маршрут не подключены.
   Исследовательский runtime host требует macOS 26.5, тогда как NeAntik 0.8.25
   поддерживает macOS 14.0; совместимый поставляемый runtime ещё не готов.
   До WebView нужно подтвердить фактически загруженный framework, а не только
   его load commands. Путь, команды JS и shell не принимаются через IPC.
   Сборочная опция пока явно отказана: runtime payload не вложен и не доверен.
2. Parent/child проверяют подпись и живую identity друг друга. Source-проверка
   теперь читает версионированный helper pin из Info.plist, сравнивает SHA-256
   и Developer ID/CDHash helper, требует физические каталоги вместо symlink и
   сверяет live code запускающего parent. Три targeted теста покрывают parser,
   symlink-путь и отказ для чужого PID. Ранний host-mode dispatch добавлен до
   обычного application lifecycle; child проверяет bundle ID и live identity,
   затем fail-closed завершается до открытия профиля, пока runtime и manager
   spawn не подключены. Это ещё не реальный spawn или подписанный прогон.
   Bootstrap, одноразовый relay-key, закрытие и состояние передаются только
   после проверки parent/child code identity через ограниченные private pipes.
   IPC-контракт умеет transport через унаследованные pipe: внешний
   length-prefix ограничивает целую запись, внутри остаётся канонический
   newline-JSON кадр. Проверен настоящий pipe round-trip; это не запуск helper
   и не подтверждение identity процесса. Bootstrap содержит абсолютный
   нормализованный data-root, ограниченный по длине; относительные пути,
   `..` и NUL отклоняются до доступа к профилю.
   При потере контроллера ключ отзывается; открытые потоки закрываются.
3. Версия runtime/store сохраняется в новом schema envelope, который старые
   менеджеры отвергают. Существующие системные WebKit-хранилища не открываются
   новым движком автоматически. Первоначально собственный runtime доступен
   только новым профилям; смена runtime существующего профиля запрещена.
4. Child сам получает lifetime guards и сверяет сохранённый профиль до WebView.
   Нельзя передать dup flock FD и затем вызвать unlock в parent. Существующие
   вкладки, клавиатура, загрузки и автосохранение переиспользуются. Неудача
   сохранения остаётся ошибкой, а не успешным завершением окна. Source-bootstrap
   перечитывает точный `isolatedV1` revision и берёт обе блокировки в child.
   Production bootstrap теперь выполняет live-проверку identity helper и
   прямого parent до проверки data root и получения блокировок. Отдельный
   `acquireForTesting` нужен только тестовым фикстурам; все 4 теста набора
   `WebKitHostChildBootstrapTests` прошли (`20261019T202004Z-42414`). Запуск
   manager → child всё ещё не подключён: это пока не процессная интеграция.
   После изменения общего startup routing прошёл полный source regression:
   Swift 1741 тест / 214 suites, Python 1745 tests. Headed и runtime gates
   не запускались.

## До включения публичного прокси

- Полная проверка совместимого архива, Mach-O minimum OS и зависимостей.
- DNS-on-wire, делегированные/фоновые подключения и нужные сетевые отказы.
- Два настоящих профиля через manager/MCP, отказ и восстановление broker,
  закрытие parent/child и сохранение данных.
- Один замороженный signed candidate: точные runtime hashes, headed UI,
  Developer ID, notarization, stapling, Gatekeeper, лицензии/attribution.
- Публичные ZIP/DMG, совпадение скачанных байтов и изолированный запуск.

Предыдущие HTTP/TLS/UDP наблюдения сохраняются как исследовательские
доказательства. Они не закрывают эту матрицу нового кандидата.

Отдельный исследовательский bundle 627.1.5+ (306 MiB) прошёл HTTP controls на
macOS 27.0, но требует macOS 26.5. Его отчёт называл strict/deep результат
Developer ID PASS; свежая проверка точного bundle завершилась
`CSSMERR_TP_NOT_TRUSTED`. Наличие подписи и Team ID не подтверждает доверенную
цепочку. Bundle не notarized и не может считаться поставляемым runtime.
Packager теперь различает недоверенную цепочку, повреждённую sealed resource,
отсутствующую подпись и прочие ошибки `codesign`; проверка точной сборки
подтвердила отдельный статус `signature chain is not trusted`, не подменяя его
выводом о повреждении bundle. Это уточнение диагностики, не изменение runtime
или release gate.
Фактическая связь load commands и результаты доверия записаны в
[`webkit-host-runtime-linkage-20261020.json`](evidence/webkit-host-runtime-linkage-20261020.json).

### 20 октября: физический bundle loader и Launch Services

Один CLI loader, размещённый внутри временного QA-bundle, разрешил `@rpath`
в его `Contents/Frameworks/WebKit.framework`; загруженный image path и SHA
зафиксированы отдельно. Сам bundle после удаления лишнего файла и повторного
ad-hoc signing проходит `codesign --verify --deep --strict`. Launch Services
по-прежнему возвращает `kLSNoExecutableErr` (`-10827`), хотя `CFBundleExecutable`
существует и Info.plist корректен. Это незакрытая ошибка harness/регистрации,
а не результат запуска WebKit. WKWebView и NetworkProcess не стартовали; сеть,
изоляция и прокси не проверялись. Не повторять такой же launch без изменения
причины. Статическая проверка подтвердила `LC_MAIN`, ARM64 и нужный `LC_RPATH`;
Gatekeeper assessment завершился внутренней ошибкой для ad-hoc bundle, а
`security find-identity` вернул 0 доступных Developer ID identities. Это
возможный фактор, но причинность не доказана. Новый сертификат не выпускался.
[Квитанция](evidence/webkit-owned-v12-bundle-load-20261020.json).


### 20 октября: узкая проверка @rpath

Отдельный CLI loader probe был явно собран с deployment target 15.4 и связан с собственным WebKit через `@rpath`; один запуск загрузил CMake build image с совпавшим SHA-256. Это подтверждает выбор image в данном layout, но не запуск WebView или сетевое поведение. Прежний UI harness напрямую вызвал NSApplication и завершился до наблюдения, а тестовый bundle не был принят Launch Services. Попытка того же loader probe со staged Frameworks завершилась SIGKILL без загруженного-image отчёта при нормальном resource gate; повтор не проводился. Не засчитывать эти setup/loader-only результаты как proxy PASS. Старый host minOS 26.5 в [linkage receipt](evidence/webkit-host-runtime-linkage-20261020.json) относится к другой сборке; новый узкий probe имел 15.4. Подробности: [loader attribution receipt](evidence/webkit-owned-load-attribution-20261020.json).


### 20 октября: staged v12 image загружен

Текущий v12 pre-sign tree собран из pinned manifest, relocator оставил 0 изменений при повторном dry-run. После ad-hoc переподписания отдельный CLI probe загрузил staged `WebKit.framework` по bundle-relative `@rpath`, получил точный image path/SHA и завершился нормально. Это закрывает только loader attribution для staged image. Вызов WKWebView, spawn NetworkProcess, enforcement и proxy A/B не выполнялись. Дерево не имеет Developer ID доверия и не годится к распространению. Проверка идентификаторов код-подписи сейчас вернула 0 доступных valid identities; выпускной сертификат не менялся. [v12 loader receipt](evidence/webkit-owned-v12-loader-qa-20261020.json).

System WebKit больше не получает production-конфигурацию upstream-прокси:
фабрика разрешает только пустую конфигурацию Direct-профиля и отклоняет явно
настроенный proxy до чтения Keychain. Синтетическая upstream-конфигурация,
оставшаяся в transport experiment, создаётся только внутри теста и не является
путём приложения. Это сохраняет отказ без Direct-fallback; фактический
изолированный WebKit proxy всё ещё не подключён и остаётся выключенным.
Проверка: [`proxy factory receipt`](../.build/neantik-local/test-receipts/20261020T043855Z-58260.json).

Дополнительный broker hardening: live NetworkProcess attestation для регистрации,
выдачи capability и привязки CONNECT выполняется вне serial listener queue.
Результат применяется только если broker всё ещё активен и в нём находится тот
же объект lease; задержанный ответ старой проверки не отзывает новую сессию.
Негативный loopback-контроль подтвердил, что stop завершается при задержанной
проверке и после stop capability не выдаётся. Suite прошёл 9/9
([evidence](evidence/webkit-broker-off-queue-attestation-20261020.json)). Это не
заменяет интеграцию manager/child или qualification поставляемого runtime.

Child bootstrap now mirrors the manager-side deletion fence: with a tombstone present, it rejects the profile before reading metadata and releases both guards. A fixture that leaves metadata in place confirmed the refusal and reacquisition of both locks: `WebKitHostChildBootstrapTests` PASS 5/5 ([receipt](../.build/neantik-local/test-receipts/20261020T044901Z-59438.json), [evidence](evidence/webkit-child-deletion-fence-20261020.json)). This is source-only; the child still does not launch WebKit, so this does not qualify network isolation.
