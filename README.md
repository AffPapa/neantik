# NeAntik

NeAntik — открытый локальный менеджер изолированных браузерных профилей для
Mac с Apple Silicon. Менеджер написан на SwiftUI и запускает встроенный
Chromium runtime, собранный из зафиксированных исходников. Electron, отдельная
установка Chrome, обязательная учётная запись и телеметрия не нужны.

[English version](README.en.md)

## Скачать приложение

Подписанное и нотарифицированное приложение опубликовано в
[GitHub Releases](https://github.com/AffPapa/neantik/releases).
Кнопка GitHub **Code → Download ZIP** скачивает исходный код, а не готовое
приложение.

Текущий опубликованный public-alpha релиз:

- NeAntik `0.3.18`, build `21`;
- macOS 14 или новее, только Apple Silicon;
- Chromium `151.0.7922.108`, ARM64, Metal;
- ZIP `NeAntik-0.3.18-arm64-notarized.zip`;
- DMG `NeAntik-0.3.18-arm64-notarized.dmg`;
- SHA-256 для обоих файлов публикуются рядом с ними в GitHub Release.

Новые изменения в ветке не являются новым бинарным релизом, пока для них не
опубликованы отдельные подписанные и нотарифицированные DMG/ZIP в Releases.

Сайт продукта: [affpapa.org/neantik](https://affpapa.org/neantik).

Возможности ниже входят в опубликованный подписанный и нотарифицированный
релиз `0.3.18 (21)`.

## Как пользоваться

1. Создайте профиль и задайте понятное имя.
2. При необходимости вставьте прокси; NeAntik распознает формат локально.
3. Нажмите «Запустить». Cookies и данные сайтов останутся только в этом
   профиле.

## Что умеет NeAntik

- хранит cookies, local storage и остальные данные в отдельных постоянных
  профилях;
- позволяет искать профили по имени и тегам, закреплять важные, убирать
  неактивные в архив и дублировать настройки в новый профиль с отдельными
  UUID, fingerprint seed и BrowserData; настройка прокси при этом тоже
  копируется;
- поддерживает Direct, HTTP/HTTPS с авторизацией через нативное окно Chromium
  и SOCKS5 без логина и пароля;
- умеет локально разобрать список прокси и создать до 100 отдельных профилей
  без автоматических сетевых запросов; при ошибке профили не сохраняются, а
  незавершённая очистка пароля помечается и повторяется при следующем запуске;
- хранит пароли прокси в Связке ключей macOS и не передаёт их в аргументах
  командной строки;
- запускает Chromium с минимальным allowlist системных переменных, не
  наследуя proxy-переменные, TLS key logs или токены из Terminal;
- не допускает повторный запуск одного профиля и корректно распознаёт живые
  helper-процессы;
- перемещает удаляемые данные профиля в Корзину, а секрет из Связки ключей
  очищает отдельным безопасным этапом;
- использует стабильный seed профиля для детерминированной изоляции
  браузерных поверхностей в совместимом Chromium runtime; новые профили
  равномерно распределяются системным CSPRNG между четырьмя проверенными
  Apple Silicon-когортами, а старые профили не ротируются;
- содержит защищённую release-only проверку A → B → A на стабильность и
  различимость профилей, не усложняя обычный пользовательский сценарий;
- не включает телеметрию в Direct-сборке.

Для HTTP/HTTPS-прокси с авторизацией отдельные кнопки копируют логин и пароль
в нативное окно Chromium. Пароль остаётся в Связке ключей и никогда не попадает
в browser CLI. Скопированное значение помечается как временное и очищается
через 60 секунд, если буфер не был изменён; в течение этого времени другие
приложения с доступом к буферу всё ещё могут его прочитать.

## Границы безопасности

NeAntik предназначен для приватности, разделения рабочих сессий, разработки и
QA. Он не обещает полную анонимность или «необнаружимость» и не предназначен
для обхода CAPTCHA, банов, антифрода или правил сторонних сервисов.

Версия `0.3.18` опубликована для public-alpha изоляции профилей. Строгая
production-согласованность всех fingerprint- и сетевых поверхностей остаётся
открытым ограничением.

Встроенный privacy-oriented Chromium собирается без Google Safe Browsing.
NeAntik не отправляет историю посещений в Google, но и не заменяет отдельную
защиту от фишинга, вредоносных сайтов и опасных загрузок. Не открывайте
недоверенные ссылки только потому, что они запущены в изолированном профиле.

Четыре когорты — проверенная продуктовая политика, а не статистика рынка и не
гарантия анонимности. Стабильный отпечаток одного профиля по назначению
связывает его повторные посещения; cookies, аккаунты, прокси, язык, поведение и
другие сигналы тоже могут связывать сессии. Сейчас политика уменьшает набор
аппаратных конфигураций, но не объединяет Canvas, Audio, WebGL и ClientRects
разных пользователей в общий отпечаток.

Каждый бинарный релиз проходит GUI-проверку A → B → A, Developer ID,
notarization, stapling, Gatekeeper и повторную проверку скачанного артефакта.
Подпись fingerprint evidence выполняется на физическом Secure Enclave точного
Developer ID-кандидата без software fallback. Подробности:
[fingerprint evidence schema 8](docs/security/fingerprint-evidence-schema-8.md).

Уязвимости следует сообщать по правилам [SECURITY.md](SECURITY.md).

## Структура репозитория

- `Sources/NeAntik` — нативный SwiftUI-менеджер;
- `Tests/NeAntikTests` — тесты менеджера, профилей, прокси и приватности;
- `runtime` — source locks, manifest патчей и лицензии Chromium;
- `scripts` — сборка, проверки, подпись и Direct release gates;
- `docs` — архитектура, приватность, runtime и выпуск;
- `releases` — метаданные и checksums публичных бинарников, но не сами
  бинарники.

Многогигабайтный Chromium checkout, build cache, `.app`, ZIP и DMG намеренно
не хранятся в Git. Runtime воспроизводится из зафиксированных upstream
исходников и открытого набора патчей. Подробнее:
[сборка из исходников](docs/BUILDING.md),
[Direct distribution](docs/DISTRIBUTION.md) и
[граница supply chain](docs/RUNTIME_SUPPLY_CHAIN.md). Текущие приоритеты и
сознательно исключённые функции перечислены в
[дорожной карте](docs/ROADMAP.md).

## Сборка менеджера

Понадобятся Mac с Apple Silicon, macOS 14+ и Xcode 26+.

```bash
./scripts/verify-native-swift-tests.sh
./Develop-NeAntik.command
```

`Develop-NeAntik.command` — быстрый цикл для интерфейса и Swift-кода. Он один
раз создаёт APFS-клон встроенного Chromium, затем пересобирает только менеджер
и открывает отдельную `NeAntik Dev.app`. У неё отдельные профили
(`NeAntik Development`) и отдельное хранилище паролей; `dist`, notarization,
GitHub и сайт не изменяются. Для проверки без открытия окна:
`./Develop-NeAntik.command --no-open`.

`Release-NeAntik.command` запускайте только для окончательного точного
кандидата: этот путь включает тяжёлые release-gates, проверку A → B → A,
Developer ID, Apple notarization и создание ZIP/DMG.

Полная Direct-сборка дополнительно требует подготовленный Chromium runtime.
Сертификат Developer ID и данные notarization остаются только в Связке ключей
владельца релиза и не хранятся в репозитории или GitHub Actions.

Выпуск идёт в два этапа: сначала создаётся и подписывается один точный
`NeAntik.app` с неизменяемым manifest всего bundle, затем свежая GUI-проверка
A → B → A привязывается к этому кандидату. Этап notarization один раз
упаковывает live app в приватный ZIP, проверяет и отправляет Apple именно эти
байты, извлекает из принятого ZIP отдельный staged app и stapler работает
только с ним. Финальные ZIP и SHA публикуются без перезаписи, ZIP — последним
commit point. Канал `public-alpha` и строгий `production` выбираются явно и не
подменяют друг друга.

`productionQualified` означает строгую согласованность fingerprint и
WebRTC-контроль для настроенного маршрута. Он не утверждает, что фактический
HTTP/DNS-выход был измерен: verifier явно возвращает
`effectiveHTTPRouteObserved=false`.

## Проверки

Основные локальные gates:

```bash
./scripts/verify-native-swift-tests.sh
python3 scripts/verify-public-fingerprint-corpus.py
python3 scripts/verify-open-source-tree.py
python3 scripts/verify-public-workflow-references.py
```

Проверка точных исходников Chromium 151 и source-qualified candidate:

```bash
python3 scripts/verify-runtime-source-provenance.py \
  /absolute/path/to/source-provenance.json \
  --source-root /absolute/path/to/chromium/src
python3 scripts/verify-runtime-candidate-lock.py \
  /absolute/path/to/runtime-candidate-lock.json \
  /absolute/path/to/source-provenance.json
```

Source contract для `151.0.7922.108` не подтверждает готовый бинарник сам по
себе. Promotion в release lock разрешён только после новой Metal-сборки и
точного schema-3 runtime verification report.

GUI evidence проверяется отдельно:

```bash
python3 scripts/verify-gui-fingerprint-report.py \
  /absolute/path/to/fingerprint-audit.json \
  --require-production
```

Диагностический или headless-отчёт не может пройти production gate. Нужен
обычный GUI-запуск с доступными и стабильными Canvas, WebGL pixels, Audio,
ClientRects, GPU metadata и Client Hints.

## Локальные данные

Профили и browser data:

```text
~/Library/Application Support/NeAntik/
```

Пароли прокси хранятся отдельно в Связке ключей macOS. Локальные fingerprint
отчёты находятся в:

```text
~/Library/Application Support/NeAntik/FingerprintAudits/
```

Отчёты имеют приватные права доступа. Публичный handoff может содержать только
агрегированную аттестацию без имён и ID профилей, seed, адресов прокси и
browser-surface значений.

## Участие в разработке

Перед pull request прочитайте [CONTRIBUTING.md](CONTRIBUTING.md). Синтетический
[fingerprint conformance corpus](docs/PUBLIC_FINGERPRINT_CONFORMANCE.md)
позволяет проверять release verifier без публикации реальных профилей,
fingerprint seed или proxy-конфигурации.
Контракт разрабатываемой аутентифицированной оболочки и её честные ограничения
описаны в
[документе schema 8](docs/security/fingerprint-evidence-schema-8.md).

Исходники NeAntik распространяются по MPL-2.0. Производные файлы Chromium
сохраняют свои upstream-лицензии и notices. Название и логотип регулируются
[TRADEMARKS.md](TRADEMARKS.md).

## Выпуск на AffPapa

Codex и Claude используют один ограниченный release-клиент. Проверить доступ,
текущий релиз и публичные файлы одной командой:

```bash
./scripts/neantik-affpapa-release doctor
```

Опубликовать уже подготовленный release-каталог:

```bash
./scripts/neantik-affpapa-release publish /absolute/path/to/release-dir
```

Ручные SSH/SCP/SFTP для этого не нужны и запрещены серверным forced-command.
Полный контракт: [ops/affpapa/README.md](ops/affpapa/README.md).
