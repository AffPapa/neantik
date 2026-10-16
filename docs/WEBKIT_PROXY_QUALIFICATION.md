# WebKit: подготовка прокси-канала

Это исследовательский срез в `DEBUG`, а не включённая функция. В опубликованном
NeAntik профиль WebKit с прокси по-прежнему отклоняется; MCP сообщает `proxy:false`.
Поставляемые Chromium, менеджер и архивы 0.8.23 не заменялись.

## Что реализовано

- Отдельный loopback HTTP CONNECT relay, не ослабляющий Chromium authority.
- Случайный пароль на сессию только в памяти. Он повторяется на соединениях
  одной сессии; это не одноразовый пароль на каждое соединение.
- Выдача конфигурации один раз для совпадающих profile/store/session/revision.
  Это проверка вызывающего кода и владения capability, не криптографическое
  доказательство принадлежности сокета конкретному `WKWebsiteDataStore`.
- `allowFailover=false`, отсутствие заданных доменных исключений. Эти свойства
  сами по себе не доказывают маршрут браузера.
- Чужой пароль отклоняется до соединения с upstream. Отзыв/отказ listener
  отменяет активные задачи; `stop()` ждёт их завершения.
- Строгий ограниченный CONNECT parser: duplicate Host/auth, неоднозначное
  framing, origin Authorization, недопустимые адреса и чрезмерный header
  отклоняются. Данные внутри туннеля не разбираются.

Используется прежний transport для HTTP/SOCKS5/HTTPS upstream; HTTPS включает
TLS. Новая связка этих upstream с WebKit ещё не квалифицирована. Тестовые
credentials собственные. Пароли не выводятся, не передаются через argv,
не сохраняются в конфигурации браузера и недоступны через MCP.

## Что проверено, а что нет

Локальные source/model/loopback controls проверяют формат, ошибочную scope,
повторную выдачу, чужой пароль, настоящий listener cancellation и завершение.
Один review выявил поздний listener failure, не отзывавший authority; это
исправлено отдельным реальным callback-контролем.

Нативные compatibility-тесты намеренно отделены от обычного CI:

| Стенд | Фактический результат |
|---|---|
| Raw NWConnection/PrivacyContext, синтетический `.invalid` адрес | `EINVAL(22)`; причина не установлена, это не доказанный отказ авторизации. |
| Ephemeral URLSession, тот же адрес | Ошибка до upstream; успешного маршрута нет. |
| Ephemeral URLSession, собственный достижимый loopback сайт | Строгий negative выявил Direct arrival и неверное тело. Свойство `allowFailover=false` этого контроля не закрыло. Это наблюдение CFNetwork на текущей среде, не доказательство поведения всех WebKit-версий. |
| Headed WKWebsiteDataStore, macOS27.0 | Один реальный запуск при normal admission: `accepted=0`, `upstream=0`, `Direct=1`. Страница загрузилась напрямую, строгий контроль отклонён. Не проверялся последующий revoke или независимый B: тест остановился на первом нарушении. |
| Новый `.invalid` host, macOS27.0 | Отдельный оконный прогон: challenge, затем authenticated CONNECT и ожидаемое тело через relay/upstream. Передача credentials на этой среде работает; старую ошибку WebKit264309 нельзя считать её текущим диагнозом. Это не проверка отказа Direct: синтетическое имя не разрешается напрямую. |
| Достижимый собственный RFC1918 IPv4, тот же новый прогон | B подтвердил достижимость точного nonce URL. A загрузил Direct-ответ без нового обращения к relay; после отзыва A снова пришёл Direct. Отдельный TCP-контроль без HTTP доказал чувствительность счётчика соединений. B оставался достижимым. Строгая приёмка — **FAIL**, production proxy выключен. |
| Явные exact `matchDomains`, macOS27.0 | Один видимый оконный прогон после исправления setup: native selectors=2, exceptions=0, failover=false. Именной CONNECT работает, но тот же собственный локальный IP снова достигается напрямую до и после отзыва. Все пять строгих нарушений сохранены; B и TCP-контроль проходят. **FAIL**, exact selector не исправляет наблюдаемый обход. |

Исходные неуспешные receipts сохраняются. Перенос experimental compatibility
в opt-in не превращает эти FAIL в PASS: обычный прогон явно показывает два
пропуска. Исследовательский канал не включается на основании unit-тестов.

## Оконный эксперимент и следующий шаг

`WebKitProxyHeadedQualificationTests` использует два свежих **nonpersistent**
хранилища и собственные endpoints. Одно окно создаёт две области: proxy
и независимый Direct. Приёмка требует разных фиксированных ответов, счётчиков
upstream/Direct, затем отзыва relay и отсутствия Direct-перехода. Кэш ответов
запрещён. Raw payload, системные fingerprint и credentials не печатаются.
Первый запуск остановился раньше этих последующих этапов. Новый эксперимент
использовал точный приватный IPv4 уже активного интерфейса этого Mac: listener
привязан только к нему, принимает только собственный peer и запрос с nonce.
DNS, hosts, маршруты, системный proxy и trust не менялись. Raw адрес не записан
в публичный отчёт. Последующие A/revoke/B этапы выполнены даже после нарушения,
поэтому доступны независимые наблюдения, а не только первый FAIL.

[Результат нового прогона](evidence/webkit-proxy-nonloopback-development.json):
одна попытка при normal pressure1/thermal1, два nonpersistent stores,
окно закрыто, relay/tasks остановлены с ожиданием, test process завершён.
Отдельное владение всеми системными WebKit-процессами не заявляется. Одна
каскадная ошибка последнего B-счётчика разобрана и исправлена офлайн: B теперь
берёт собственный baseline после A. Исходные шесть issues, точные байты
выполненного fixture и FAIL сохранены. Исправление скомпилировано; нативный
прогон не повторялся.

[Минимизированные результаты](evidence/webkit-proxy-development.json) разделяют
source controls, CFNetwork failure и фактический WebKit failure. Отдельный
[exact-match прогон](evidence/webkit-proxy-exact-match-development.json)
теперь также отклонён: документированный suffix selector не устранил обход
локального IP на этой среде. Эти defaults/exact варианты повторять без новых
входов не нужно. Не применять недокументированные wildcard-значения и не
переносить NetworkExtension settings на per-store API. SOCKS frontend остаётся
отдельным исследовательским вариантом с собственной приёмкой, не готовым
исправлением. Заменять отказ
Direct-подключением или разрешать relay всем Apple-процессам нельзя.

Перед запуском нужен свежий normal admission. Разовое исключение warning
допустимо только после прямого разрешения человека для этого эксперимента;
fixture повторно проверяет давление и температуру перед созданием views.
Critical/unknown и серьёзный перегрев всегда запрещены. Предыдущие разрешения
DOM/V8/Workers или CoreText на этот эксперимент не распространяются.

Даже успешный эксперимент не закрывает persistent UUID stores, реальный
manager lifecycle, HTTPS destination/upstream, remote DNS, UDP/WebRTC,
доступные Direct exceptions и одновременные сессии. Они остаются обязательными
до production enable. При отзыве живому store нельзя назначать пустой список
proxyConfigurations: это изменило бы маршрут на Direct.

## Результат exact-match варианта

У QA-fixture есть отдельный режим
`NEANTIK_WEBKIT_PROXY_NONLOOPBACK_MATCH_MODE=exact-hosts`. Он назначает две
явные записи `matchDomains` — собственный адрес и случайное `.invalid`
имя — до присоединения конфигурации к store и первого запроса. Пустых строк
или wildcard нет. Неизвестный режим отклоняется до setup; значения адресов и
объект proxy не передаются в диагностические assertions.

Четыре чистых model-теста и два связанных CI/catalog-контроля прошли. Первый
test host остановился на проверке конфигурации до создания окна. Отдельный
in-memory контроль показал расхождение readback на установленной macOS:
Swift `excludedDomains` возвращает две записи из match list, тогда как
публичный C API того же объекта возвращает ноль исключений. Fixture теперь
проверяет реальные selectors, exceptions и failover через публичный C API.
Отрицательные контроли ловят добавленное исключение, разрешённый failover и
неверные selectors, в том числе список той же длины.

Разрешённый этап завершён: два test host, из которых первый не создал окно,
и один фактический оконный прогон. При warning использовано разрешённое
исключение; thermal=0. После исправления readback strict gate снова выявил
Direct arrival до и после отзыва, пять issues, exit1. Окно закрыто, relay и
fixture tasks остановлены с ожиданием, test host завершён. Повторного запуска
нет; исходный setup FAIL не заменён успешным результатом. Список покрывает
только два тестовых адреса. Другие macOS и произвольный маршрут этим не измерены.

## Источники API

Установленный SDK объявляет per-store proxy с macOS14; версия15 не требуется.
Публичный HTTP CONNECT API описывает TCP, но не гарантирует confinement DNS/UDP.
См. [Apple ProxyConfiguration](https://developer.apple.com/documentation/network/proxyconfiguration),
[HTTP CONNECT initializer](https://developer.apple.com/documentation/network/proxyconfiguration/init(httpconnectproxy:tlsoptions:))
и `WKWebsiteDataStore.h` установленного SDK.

## SOCKS5: оконный эксперимент не устранил обход

В DEBUG подготовлен отдельный SOCKS5 frontend существующей session. Он
использует публичный `ProxyConfiguration(socksv5Proxy:)`, а не Chromium
listener с анонимным методом и signed-PID authority. Lifecycle, scope,
лимит соединений, общий пятисекундный handshake deadline, отмена и upstream
transport общие с HTTP CONNECT; default frontend остаётся HTTP CONNECT.

Метод username/password обязателен. Случайные session credentials остаются
только в памяти и задаются native credential API. Парсер сохраняет границы
greeting/auth/CONNECT и последующие bytes; секреты скрыты при reflection.
Анонимный метод, чужая/неверная авторизация и UDP/BIND не должны открывать
upstream. После авторизации повторно проверяется session; success отправляется
только после установленного upstream. Сам relay разрешает только TCP и не
разрешает имя конечного сайта локально. Это не доказательство отсутствия DNS
или UDP вне relay в самом WebKit.

17 pure model/parser controls и 11 CI-контролей прошли до native-этапа.
Они не доказывают маршрут. Один разрешённый этап завершён 16 октября 2026:
четыре raw-stream случая и одно видимое окно с двумя временными хранилищами.
Два теста в двух suites завершились с **шестью issues**, не с PASS.

**Авторизация работает. Ограничение маршрута — нет.** Именованный запрос
WebKit прошёл SOCKS method2 и получил ответ через upstream. Затем собственный
доступный private-IP endpoint получил запрос A напрямую: до и после отзыва
relay. Независимый B подтвердил доступность origin; bare TCP отличил приход
соединения от HTTP-ответа. Пять строгих route assertions остались FAIL.

| Фаза | Соединения Direct, накопительно | HTTP-ответы Direct, накопительно |
|---|---:|---:|
| Именованный запрос A | 0 | 0 |
| Direct-контроль B | 1 | 1 |
| Bare TCP-контроль | 2 | 1 |
| Защищаемый IP-запрос A | 3 | 2 |
| A после отзыва relay | 4 | 3 |
| Direct-контроль B после отзыва | 5 | 4 |

Четыре raw случая не открыли upstream (`0` соединений, `0` established);
wire/EOF assertions не дали issues. Однако общий assert счётчиков отказов
упал отдельно. Значения счётчиков не записаны — конкретный неверный conjunct
неизвестен. Найден дефект исходников: общий catch классифицировал отмену и
transport error как неверную авторизацию. Catch сужен до malformed auth,
добавлена проверка отмены; исправление **только скомпилировано** за 11,462 с.
Native-проверка исправленного обработчика не выполнялась. Критерии теста
не ослаблялись; атомарность счётчика с отзывом отдельно не доказана.

Окно закрыто, relay drained, остановка fixture tasks дождалась завершения,
тестовый процесс вышел. Это не доказательство custody всех системных процессов
WebKit. Точный тестовый бинарник и исходники сохранены;
[обезличенный результат с хешами](evidence/webkit-proxy-socks-development.json)
отделяет исходное наблюдение от последующей правки.

**Перебор HTTP/default/exact/SOCKS прекращён:** все проверенные варианты
сохранили Direct bypass. Production WebKit proxy остаётся выключенным.
Перед следующим native-этапом нужен подтверждённый исходниками проект сетевой
границы. Persistent stores, manager lifecycle, HTTPS/DNS/UDP и другие macOS
остаются отдельными gates. Исследовательское окно не заменяет квалификацию
подписанного продукта. Израсходованное разрешение не используется повторно.

Основания эксперимента: [Apple SOCKSv5 initializer](https://developer.apple.com/documentation/network/proxyconfiguration/init(socksv5proxy:)),
[RFC1928](https://www.rfc-editor.org/rfc/rfc1928.html) и
[RFC1929](https://www.rfc-editor.org/rfc/rfc1929.html). Наличие API не обещает
устранение уже измеренного local-IP bypass.

## Следующая граница: архитектура, а не ещё один протокол

Проверены заголовки установленного SDK: `WKWebsiteDataStore.h:125–132`,
`Network/proxy_config.h:219–298`. Они предоставляют конфигурации прокси,
failover и suffix selectors; доказанного переключателя force-local/route-all
не найдено. Upstream WebKit сериализует настройки в
[WKWebsiteDataStore.mm](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/Cocoa/WKWebsiteDataStore.mm#L516)
и передаёт их в системный сетевой контекст в
[NetworkSessionCocoa.mm](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/NetworkProcess/cocoa/NetworkSessionCocoa.mm#L1811).
Это просмотр `main` 16 октября 2026, не исходники точного установленного
бинарника macOS; причину обхода ниже этих границ мы не установили.

Дальше допустимы два технических пути: конкретное исправление Apple/WebKit
либо другая архитектура с принудительной сетевой границей на профиль.
До новой реализации нужно показать, как она охватывает DNS/UDP, workers,
subresources и WebSocket, блокирует Direct после отзыва и не затрагивает B.
Глобальная системная настройка или доверие всем Apple-процессам по UID
этого требования не выполняет. Пока WebKit остаётся Direct-only, а профили
с прокси используют Chromium.

`WKURLSchemeHandler` не заменяет сетевой контроль: SDK прямо запрещает
обработчик схем, которые WebKit обслуживает сам, включая HTTP/HTTPS
([проверка WebKit](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/Cocoa/WKWebViewConfiguration.mm#L523)).
Navigation delegate также не покрывает все сетевые запросы. Другое имя relay
или флаг без подтверждённой семантики не являются основанием нового прогона.

### Заготовка воспроизведения для Apple/WebKit

Отчёт **не отправлен**. Сохранённое воспроизведение:
[точный тест](https://github.com/AffPapa/neantik/blob/8187fde6bfeb02e6f23a8db44d9ccb53db151db1/Tests/NeAntikTests/WebKitProxyTransportTests.swift#L527)
и [точный DEBUG relay](https://github.com/AffPapa/neantik/blob/8187fde6bfeb02e6f23a8db44d9ccb53db151db1/Sources/NeAntik/WebKitProxySession.swift).
Это проектный harness, не отдельно квалифицированный минимальный sample.

1. На macOS27.0 ARM64/system WebKit22625.1.29.11.24 создать два временных
   nonpersistent stores, один visible window, собственный reachable private-IP
   HTTP origin и собственный loopback authenticated proxy. Системные настройки
   не менять; test credentials случайные, только в памяти.
2. До первого WKWebView задать A `proxyConfigurations` с SOCKSv5, credentials,
   `allowFailover=false`, native exception count0 и exact match domains для
   своего synthetic `.invalid` имени и выбранного private IP. B — Direct.
3. Убедиться, что имя через A достигло proxy и вернуло upstream ответ;
   B получает отдельный origin ответ; bare TCP даёт arrival без HTTP-ответа.
4. Обратиться через A к собственному private IP. Ожидание: proxy route или
   отказ. Факт: отдельный Direct origin arrival и ответ без нового upstream.
5. Отозвать relay, не очищая назначение store A. Ожидание: отказ без origin
   arrival. Факт: ещё один Direct arrival и ответ. B остаётся доступным.
6. Закрыть окно, дождаться relay tasks и fixture stops. Полные журналы,
   адреса и credentials не включать в публичное обращение; приложить
   обезличенные счётчики/версии/хеши из linked JSON.

Новый native-этап допустим при конкретном изменении проверяемой сетевой
поверхности, а не для повторения этого FAIL. Все прежние ограничения и
обязательная квалификация точного кандидата остаются открытыми.

## Начата реализация отдельной сетевой границы

[Development package](../Experiments/WebKitIsolation/README.md) отделён от
поставляемого менеджера. Реализованы ограниченный реестр полных audit tokens,
короткие session leases, отзыв активных потоков, точная Developer ID/CDHash
проверка живого процесса и adapter реальных `NEAppProxyTCPFlow`. Основа —
`NEAppProxyProvider` system extension: отказ этого provider завершает поток;
у transparent provider отказ может означать Direct.

18 уникальных чистых controls прошли (12 ledger + 6 lifecycle/callback,
с намеренно неверным порядком callbacks как negative control); adapter
скомпилирован. Уже пройденные 12 ledger tests не повторялись после правок
отдельного lifecycle. Это не установленная
сетевая изоляция: ещё нужны dedicated host, аутентифицированный control IPC,
конкретный proxy tunnel, реальные kernel rules и квалификация маршрута.
Наличие `NEAppRule` объекта не доказывает применение правил системой.
[Точный состав и границы](evidence/webkit-network-isolation-development.json).

На первом этапе проверены65 существующих provisioning profiles: нужных
Network Extension / System Extension разрешений не было. После отдельного
точного подтверждения зарегистрированы только два QA App ID и выпущены
Developer ID profiles с тем же сертификатом135. CMS подписей и точные grants
проверены; два изменения подписанного содержимого отвергнуты. Новые сертификаты
и production account changes отсутствуют. Системные настройки не менялись.
До реальных gates WebKit proxy остаётся выключенным; план1.0 не закрыт.

Подготовлен следующий kernel probe: отдельный controller без WebKit,
пустые nonpersistent Host A/B и deny-only provider. Три executables
скомпилированы; исходные четыре unsigned bundles сохранены, отдельная свежая
QA-копия теперь подписана прежним Developer ID с точными claims. Запуск и
установка не выполнялись. Controller отказывается сохранять global/destination-IP scope
или запускать устаревшее правило: принимается только source-application scope
для точного QA Host A. Правило и counters не считаются доказательством маршрута.
Сначала требуется подтвердить actual kernel capture и B/provider-stop controls;
только затем интегрировать настоящий tunnel и production host/IPC.


QA source review additionally fixed strict literal-IP parsing and asynchronous
launch/cleanup overlap. Seven new pure controls passed; prior18 ownership/
lifecycle controls were not replayed. The current total is25 unique pure
controls, not25 browser measurements. All QA executables compile; four fresh
bundles are Developer ID signed and strict-verified. Both approved QA profiles
are authenticated, using the same certificate as release135. No extension or
browser was executed or installed. Apple notarization remains pending after
an automatic-review refusal of the exact private-code upload; a separate scoped
request is open. No production capability has been enabled.
