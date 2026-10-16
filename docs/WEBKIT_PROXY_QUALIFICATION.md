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
source controls, CFNetwork failure и фактический WebKit failure. Далее нужно
проверить отдельно явный exact `matchDomains` на тех же собственных типах
endpoint. Это документированный suffix selector, но приоритет над фактически
наблюдаемым local-IP bypass документацией не гарантирован. Не применять
недокументированные wildcard-значения и не переносить NetworkExtension settings
на per-store API. Если exact selector не поможет, SOCKS frontend — отдельный
исследовательский вариант, не готовое исправление. Заменять отказ
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

## Подготовленный exact-match вариант

У QA-fixture есть отдельный режим
`NEANTIK_WEBKIT_PROXY_NONLOOPBACK_MATCH_MODE=exact-hosts`. Он назначает две
явные записи `matchDomains` — собственный адрес и случайное `.invalid`
имя — до присоединения конфигурации к store и первого запроса. Пустых строк
или wildcard нет. Неизвестный режим отклоняется до setup; значения адресов и
объект proxy не передаются в диагностические assertions.

Три чистых model-теста и два связанных CI/catalog-контроля прошли. Нативный
exact-match результат ещё не получен: нужен отдельный допуск. Прежний запуск
с defaults не повторяется. Этот список покрывает только два тестовых адреса,
а не произвольную работу браузера; даже PASS не даст production proxy:true.

## Источники API

Установленный SDK объявляет per-store proxy с macOS14; версия15 не требуется.
Публичный HTTP CONNECT API описывает TCP, но не гарантирует confinement DNS/UDP.
См. [Apple ProxyConfiguration](https://developer.apple.com/documentation/network/proxyconfiguration),
[HTTP CONNECT initializer](https://developer.apple.com/documentation/network/proxyconfiguration/init(httpconnectproxy:tlsoptions:))
и `WKWebsiteDataStore.h` установленного SDK.
