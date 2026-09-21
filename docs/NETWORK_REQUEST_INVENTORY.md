# Инвентаризация сетевых обращений NeAntik

Проверено 21 сентября 2026 года по текущему Swift-коду, ресурсам приложения,
launch-policy и release-скриптам. Этот документ разделяет подтверждённые
manager-поверхности и поведение встроенного Chromium. Он не является
доказательством фактического сетевого маршрута браузера.

## Подтверждённые обращения менеджера

| Поверхность | Когда выполняется | Адрес/механизм | Данные и ограничения | Статус |
| --- | --- | --- | --- | --- |
| Проверка прокси | Только по действию пользователя и свежо перед прокси-запуском | `/usr/bin/curl` -> `https://ipapi.co/json/` через введённый proxy | Временный stdin-конфиг; пароль не попадает в аргументы. Ответ ограничен 16 KiB и проверяется по схеме. UI показывает только безопасный контекст; raw IP не входит в `ProxyHealthSuccess` и не сохраняется | verified |
| Optional telemetry | Только если endpoint задан в `Info.plist`, пользователь дал consent и событие разрешено | `URLSession` -> HTTPS endpoint | Только агрегированные счётчики профилей, версия/build, архитектура, ОС и тип события. Exact host policy: `affpapa.org`, `browser.free`, `github.com`; без credentials/query/fragment и нестандартного порта. В Direct resource endpoint пустой, поэтому обращений нет | verified / disabled in Direct |
| Public stats link | Только как пользовательский переход, если URL задан | HTTPS URL из `Info.plist` | Тот же exact host policy; в Direct URL пустой | verified / disabled in Direct |
| Signed update manifest | Offline verification of a supplied manifest | Сеть не выполняется менеджером | URL только валидируется по exact host policy; automatic update и download выключены | verified / disabled |
| Release download verification | Только отдельными release-скриптами оператора | `curl` в `verify-direct-hosted-download.py` и связанных gates | Release-only surface; HTTPS, ожидаемое имя архива, sidecar/hash и размер привязаны к локальному кандидату | verified / operator-only |

## Встроенный Chromium

Swift-менеджер передаёт браузеру только проверенные launch-ограничения:

- для proxied-профиля — proxy server, запрет non-proxied UDP, `--disable-quic`,
  fail-closed resolver rules и ограниченный bypass только для loopback;
- для Direct-профиля — `--no-proxy-server` и `default_public_interface_only`;
- окружение дочернего процесса очищается от ambient proxy/TLS/token-переменных;
- `additionalArguments` проходят через denylist защитных prefix-ов.

Это политика запуска, а не инвентаризация всех запросов Chromium. Полный
список фоновых запросов, DNS/TLS/HTTP3 и поведение сетевого стека невозможно
честно подтвердить из Swift-менеджера без точного исходного дерева и
runtime-измерения. Поэтому этот пункт остаётся `unverified` до разрешённой
пересборки Chromium и полного runtime/network evidence cycle.

## Что намеренно не считается сетевым обращением

- локальный loopback network-reality harness — тестовый producer, а не
  production endpoint;
- `URL(fileURLWithPath:)` и чтение локальных JSON/manifest-файлов;
- `xcrun notarytool`, `stapler`, Gatekeeper и upload-команды — внешняя
  release-инфраструктура, не фоновая функция продукта;
- URL стартовой страницы пользователя — явный navigation input, а не
  скрытый manager background request.

## Приёмка

Сейчас aggregate audit должен честно оставаться `partial`: manager network
поверхности инвентаризированы, локальный harness не доказывает внешний маршрут,
а runtime security/rebase gates заблокированы до точной Chromium 153 macOS
source/packaging pair и отдельного разрешения пересборки.

Нельзя превращать launch flags, proxy configuration или успешный ответ
`ipapi.co` в заявление о полной анонимности, необнаружимости или обходе
контролей третьих сторон.
