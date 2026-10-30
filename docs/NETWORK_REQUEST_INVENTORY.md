# Сетевые обращения NeAntik

Сверено с исходниками после выпуска [0.8.14 (126)](../releases/v0.8.14.json).
Это описание того, когда выполняются запросы и что они доказывают. Оно не
означает, что весь трафик Chromium уже измерен на проводе.

## Менеджер и служебные процессы

| Операция | Когда и куда | Данные и ограничения |
| --- | --- | --- |
| Проверка прокси | По действию пользователя и по policy подготовки запуска; curl через выбранный прокси к `https://ipwho.is/` и `https://free.freeipapi.com/api/v1/json`, при допустимом отказе пары — резервный `https://ipapi.co/json/` | Пароль передаётся stdin, а не argv. Ответ ограничен 16 KiB. Несогласованные/невалидные ответы, отказ авторизации и протокола не подменяются резервным успешным ответом. HTTP-ошибка IP-сервиса отделяется от CONNECT/auth ошибки. Это preflight, не маршрут Chromium. |
| Собственный endpoint | Только явная диагностика с consent, curl через выбранный прокси к заданному HTTPS endpoint | Проверяются адрес/размер/timeout; redirect и fallback запрещены. Результат не назначает GeoIP-контекст и не доказывает DNS/TLS-маршрут браузера. |
| Получение обновления | По кнопке проверки обновления, к закреплённому manifest URL установленного приложения | Ephemeral URLSession без cookies, credential storage и cache; timeout запроса 15 с, операции 20 с, максимум 128 KiB. Требуются exact URL, HTTP 200, JSON MIME и подпись Ed25519. Redirect и запрос входа отклоняются. ZIP автоматически не скачивается: пользователь выбирает архив, который отдельно проверяется перед предложением установки. |
| Telemetry / публичная статистика | Только при настроенном endpoint и предусмотренном consent/явном переходе | В Direct endpoint и stats URL пустые: эти обращения выключены. Факт отключения не распространяется на сторонние сайты открытого профиля. |
| Per-profile relay Chromium | Пока действует проверенная authority конкретного профиля и сессии | Локальный маршрут с авторизацией upstream; секреты не помещаются в browser argv. HTTPS upstream использует отдельный TLS/trust путь. Positive с OS-default-trusted authenticated HTTPS upstream отложен пользователем; его нельзя объявлять проверенным. |
| Browser-route диагностика | Только при явном ограниченном HTTP/HTTPS плане и доступной session authority | Подписанные receipts связаны с nonce, endpoint и сроком; результат зависит от текущих revision/policy/session. Истёкшее наблюдение не остаётся зелёным. Подтверждённый HTTP(S) endpoint или переданное hostname не доказывают отсутствие всех DNS/UDP-путей. |
| Release download verifier | Только инструмент оператора, анонимная загрузка опубликованных GitHub assets | Проверяются HTTPS, имя/размер/SHA-256 и соответствие точному подписанному кандидату. Это не фоновая функция браузера. После 0.8.14 общий downloader отключает curlrc/ambient proxy credentials/TLS overrides и не возвращает сырые stderr. Приложение 0.8.14 от этой source-only правки не меняется. |

Свежесть proxy-health привязана к конфигурации и revision, а не к одному старому
зелёному результату. GeoIP — отдельная оценка окружения; совпадение страны и IP
не заменяет измерение сетевого пути Chromium.

## Chromium и WebKit

У Chromium сохранены per-profile launch policy, relay, ограничение non-proxied
UDP/QUIC и запрет незаметного Direct fallback. Настроенные flags сами по себе
не являются доказательством фактического маршрута. Контролируемые HTTP/HTTPS,
отказы relay и ограниченные background-наблюдения находятся в отчётах выпусков;
доказательства неизменённого M156 runtime повторно не запускаются без причины.
DNS-on-wire, все UDP-пути, смена сети и полная фоновая матрица остаются открытыми.

WebKit использует системный сетевой стек. Настроенный прокси пока вызывает
отказ запуска; прямое соединение вместо него не допускается. Работающий
Chromium relay не считается готовой поддержкой прокси WebKit.

## Что считается отдельной инфраструктурой

- Запросы открываемых пользователем сайтов — navigation input, не скрытая telemetry.
- Loopback fixtures и synthetic QA-профили — отдельные измерения, не production endpoints.
- GitHub upload, Apple notarytool/stapler/Gatekeeper и Sites — инфраструктура выпуска.
- [Network Reality harness](NETWORK_REALITY_HARNESS.md) проверяет ограниченный
  контракт отчёта. Legacy Python-запрос не квалифицирует Chromium или DNS.

## Источники и следующие проверки

- [ProxyTester](../Sources/NeAntik/ProxyTester.swift),
  [ProxyHealthCoordinator](../Sources/NeAntik/ProxyHealthCoordinator.swift).
- [SignedUpdateManifestFetcher](../Sources/DirectUpdateCore/SignedUpdateManifestFetcher.swift),
  [ApplicationUpdateController](../Sources/NeAntik/ApplicationUpdateController.swift).
- [BrowserRouteProbe](../Sources/NeAntik/BrowserRouteProbe.swift),
  [relay transport](../Sources/NeAntik/ProxyRelayUpstreamTransport.swift).
- [Очередь 1.0](NEXT_1_0_SLICES.md): следующий P0 — контролируемый DNS-on-wire
  producer и реальные positive/negative controls. Исправленный документ этот gate не закрывает.

Ни preflight curl, ни launch flags, ни отдельный detector не дают гарантии
анонимности или обхода правил сторонних сайтов.
