# NeAntik changelog

## Unreleased

## Direct 0.3.23 (26) — September 1, 2026

- Removed the dormant telemetry network client, signed-manifest prototype and
  historical external Chrome/Cloak preference path. Direct now contains no
  telemetry/update configuration keys, launches only the declared embedded
  runtime and enforces those absences in source, privacy and release gates.
- Creating a new Direct profile without proxy authentication no longer makes
  a redundant Keychain deletion request.
- The primary Create button keeps opening the full editor, while its menu now
  offers a safe quick path that creates and opens a permanent Direct profile
  with a collision-free local name, fresh session and fresh identity. It does
  not copy a proxy, note, account secret or previous BrowserData.
- A selected running profile can bring its Chromium window forward from the
  row menu or the fixed local `Shift-Command-Return` command. The existing
  visible Stop action and Force Stop confirmation remain separate.
- Keyboard commands now stay disabled under every sheet and alert, including
  Force Stop. Start/Stop, inspector, profile edit and note edit use one fixed
  menu-backed shortcut catalog; the batch bar no longer steals `Command-Z`
  from text editing, the hidden readiness `Command-R` is gone, and Escape
  clears then leaves profile search.
- A native Settings window remembers only the local row density and shows the
  complete shortcut reference. It adds no remappable/global hotkeys,
  dependency, background service, profile field or runtime byte.
- Direct release preflight now verifies that the external provisioning
  profile actually authorizes the exact pinned Developer ID certificate, then
  repeats that certificate-to-profile check on the signed app before Secure
  Enclave enrollment. A wrong certificate selection now fails before the
  expensive build instead of being killed later by macOS `taskgated`.
- GitHub README and project documentation now identify the actual immutable
  `0.3.22 (25)` release instead of continuing to label it a source candidate.
  A current code-owner map and a dated comparison of twenty profile browsers
  record what is delivered, deferred and deliberately excluded.
- Readiness and proxy feedback use explicit information, success, warning and
  failure semantics. Permission help is collapsed so the real readiness rows
  stay visible, and the compact workspace keeps Start/Stop on the same side as
  the wide layout.
- Notes open in a small dedicated editor with existing plaintext and size
  warnings; users no longer need to open unrelated proxy/fingerprint fields.
  Secondary list actions have a visible name, search has a shorter prompt and
  Force Stop is a visible destructive action with the existing confirmation.
- No dependency, profile schema, runtime byte, fingerprint policy, launch
  argument or public release artifact changes in this source iteration.
- The default release `doctor` now verifies Direct/GitHub tooling and the
  latest immutable GitHub assets without requiring a website deploy key.
  The restricted AffPapa access check is an explicit `site-doctor` used only
  for a separately authorized website transaction.
- ContentView request, presentation and list-cache state now has a separate
  source owner. The main view is 182 lines smaller and its fail-closed budget
  was lowered from 4,400/170,000 to 3,800/145,000 lines/bytes without changing
  profile, runtime, filesystem, network or Keychain behavior.
- CI now scans every reachable Git blob and historical filename for private
  keys, provisioning profiles, `.env` files, known service-token formats and
  assigned recovery phrases without printing a matched value. Current-tree
  publication checks and GitHub secret scanning remain separate gates.

## Direct 0.3.22 (25) — August 31, 2026

- Direct-кандидат теперь подписывается только с проверенным внешним Developer
  ID distribution provisioning profile и точными `keychain-access-groups` для
  `app.neantik.desktop`. Профиль не хранится в Git; release gate проверяет его
  CMS-подпись, срок, team/bundle, запрет development/ad-hoc и уже подписанные
  entitlements до обращения к физическому Secure Enclave.
- Основной сценарий редактора перестроен вокруг ежедневной задачи: название
  и видимая необязательная заметка идут первыми, затем необязательный прокси;
  папка, теги, стартовая страница, цвет и иконка собраны под одной строкой
  «Дополнительно».
- Строка профиля теперь текстом показывает состояние и маршрут, выводит
  ограниченную однострочную заметку и оставляет подписанную кнопку
  «Старт»/«Стоп» непосредственно рядом с профилем. Редактор предупреждает не
  хранить в заметках пароли, ключи и seed-фразы.
- Обычное создание стало главным действием списка, а массовые создание и
  проверка прокси перенесены в дополнительное меню. Новых зависимостей,
  изображений, фоновых запросов и изменений Chromium runtime нет.
- Список профилей получил компактные режимы
  сортировки и фильтр «с прокси»/«без прокси». Общий поиск умеет находить
  профиль по отображаемому маршруту, но не индексирует учётные данные прокси
  и другие секреты.
- Остановка встроенного Chromium теперь имеет ограниченный трёхсекундный
  grace-период: если управляемый текущим NeAntik процесс игнорирует SIGTERM,
  завершается только этот точный дочерний процесс. Чужие и восстановленные
  PID по-прежнему не получают принудительный сигнал.
- Локальная Dev.app синхронизирует version/build с source candidate. Live
  manager и browser-mode fingerprint gate выполняются на точной подписанной
  dist-сборке, поскольку ad-hoc Dev-клон не является release evidence.
- Workspace стал list-first: профили занимают основную область, а полная
  карточка открывается в необязательном нативном inspector по `Command-I`.
  Широкая строка показывает профиль, статус, подключение, контекст и действие,
  а на минимальном окне автоматически становится компактной.
- Появился явный множественный выбор профилей и атомарные пакетные действия:
  закрепить, переместить в папку, добавить или убрать тег и архивировать.
  Последнее пакетное изменение можно отменить; конфликт новой ревизии
  прекращает откат без частичного восстановления.
- Поиск получил локальные операторы `тег:`, `папка:`, `прокси:` и `статус:` с
  кавычками для значений с пробелами. Обычный поиск по имени, заметке и
  отображаемому маршруту сохранил прежнюю семантику и линейный бюджет на
  10 000 профилей.
- Массовый импорт прокси принимает вставленный текст и локальные TXT/CSV-файлы.
  Файл читается с ограничением размера, без перехода по symlink и без
  автоматических сетевых запросов; UTF-8 BOM удаляется до предпросмотра.
- В карточке профиля появилось запускаемое только по запросу измерение места:
  оно показывает реально выделенные байты и число файлов BrowserData, не
  переходит по символическим ссылкам и не замедляет список профилей.
- Приватные metadata-файлы профилей, организации и release evidence теперь
  открываются descriptor-first с `O_NOFOLLOW`, проверкой типа, hardlink,
  предельного размера и неизменности inode до и после чтения. Заведомо большой
  файл отклоняется до выделения памяти.
- Запуск разделён на пять проверяемых этапов: runtime, storage, proxy,
  consistency и process. Ошибка указывает точный этап, а запуск блокируется
  при недоступной папке данных или менее 1 ГиБ свободного места.
- Жизненный цикл профиля различает запуск, штатное закрытие, ожидание и
  отдельную подтверждаемую принудительную остановку. Компактная полоса
  активных профилей показывает Focus/Stop и время работы; SIGKILL больше не
  выполняется автоматически после тайм-аута.
- NeAntik записывает минимальное локальное доказательство неожиданного
  завершения менеджера без профилей, путей или сетевых данных. Одновременно
  разрешено не больше 12 управляемых запусков.
- Запущенный профиль можно редактировать с предупреждением, что параметры
  применятся при следующем запуске. «Дублировать» заменено на «Создать
  похожий» с явным пояснением новой сессии и идентичности.
- Массовая проверка прокси показывает успешные и ошибочные результаты и умеет
  повторить только ошибки. Форматы стали короче, а подробности проверки и
  авторизации собраны в один раскрываемый блок.
- Добавлен нативный «Центр готовности»: он локально проверяет приложение,
  встроенный Chromium, общую папку данных, процессы и подключения, объясняет,
  что в разрешениях macOS нужно выбирать основной `NeAntik.app`, и копирует
  только ограниченную диагностику без секретов, IP и путей профилей.
- Детерминированный аудит установленного размера разделяет manager, runtime,
  compliance и прочее и показывает фактическую причину веса — встроенный
  Chromium. Добавлены бюджеты Swift-файлов, cold/warm readiness и CPU/RSS
  менеджера без Chromium.
- Direct release evidence прекращается при любой ошибке Secure Enclave:
  production-код не создаёт экспортируемый software-key, release gate
  запрещает App Sandbox и проверяет update metadata упакованного кандидата.
- Удалённый профиль сразу исчезает из локальных UI-состояний даже при
  отложенной очистке Keychain. VoiceOver получил явные подписи выбора,
  профиля, статуса и подключения.
- Изменение не добавляет зависимости, изображения, фоновые службы и не меняет
  встроенный Chromium `152.0.7977.64`.

## Direct 0.3.21 (24) — August 30, 2026

- Исправлена фактическая причина пользовательского сбоя обновления: release
  flow и документация теперь однозначно отделяют старую ссылку сайта от
  immutable GitHub-артефакта, а пустая ошибка запуска ведёт к диагностике
  среды и переустановке из официального DMG без удаления данных профиля.
- Заметка раскрыта по умолчанию при создании профиля и явно помечена как
  необязательная. В карточке профиля блок заметки показывается всегда: пустое
  состояние предлагает «Добавить заметку…», заполненное — изменить её.
- Перед Developer ID signing локальные символы Chromium удаляются только из
  временной неподписанной копии Apple `strip` из совместимого Xcode. Каждый
  Mach-O повторно проверяется как ARM64 и должен содержать не больше одного
  служебного local symbol; llvm-strip 22 по-прежнему запрещён. На Chromium
  152 это убирает около 125 МиБ из установленного приложения без удаления
  локалей, лицензий, notices, SwiftShader, crashpad или security evidence.

## Direct 0.3.20 (23) — August 30, 2026

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
