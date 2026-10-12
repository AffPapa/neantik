# Изоляция данных при квалификации updater

Статус: реализован source-контракт, локальные тесты. Полное обновление подписанного old → new через GUI ещё не квалифицировано. Публичный updater выключен.

Для интерактивной проверки используется отдельный защищённый control mode
`--neantik-release-update-audit --candidate-manifest MANIFEST --output OUTPUT`.
OUTPUT допустим только в приватном каталоге
`/private/tmp/neantik-update-audit-<lowercase UUID>/update-audit.json`.
Manifest проходит тот же exact executable/version/build/binding loader. Затем
приложение подтверждает доступ к уже enrolled Secure Enclave authority отдельной
domain-separated подписью до создания manager-data. Отсутствующий ключ, другой
публичный ключ или неверная подпись отклоняются. Один pathname не даёт полномочий.
Режим сохраняет изоляцию и native mock Keychain браузера, но не запускает
fingerprint-проверку автоматически и не создаёт evidence PASS. Это позволяет
пройти настоящий интерфейс updater. Обычный запуск и обязательный release
fingerprint gate остаются прежними. 29 targeted tests и полный последовательный
прогон 1417 tests /162 suites прошли; это ещё не квалификация установки.

## Причина

После существующего bootstrap handshake новый процесс переходил к обычному startup без предыдущего release-audit root. Такая проверка могла выбрать production AppPaths. Не следует запускать этот эксперимент на реальных профилях. Нельзя загружать прежний FingerprintEvidenceReleaseContext заново: он привязан к прежним version/build/executable и содержит отдельные полномочия подписи и challenge.

## Контракт

- Только уже аутентифицированный release-audit GUI создаёт контекст изоляции. Нет выбора root через argv, environment или MCP.
- Допустим только приватный `/private/tmp/neantik-update-audit-<lowercase UUID>/manager-data`. Родитель и root удерживаются открытыми descriptors; UID, inode/device, mode0700, отсутствие ACL/flags и nofollow проверяются повторно.
- Bounded NUI2 init включает root custody и digest уже проверенного prepared manifest. Его размер допускается до1MiB;128KiB — другой контракт, signed updater envelope.
- Offer/consent/Accepted связываются с полным init digest. Эти сообщения не дают права установить приложение.
- После начала существующей транзакции exact live owner публикует отдельную0600 sealed запись через EXCL rename и directory sync внутри своего retained workspace. Запись привязана к полному192byte bootstrap request.
- Candidate получает адрес записи только из kernel executable path уже аутентифицированного exact owner. Проверяет запись, root и новый domain-separated digest до128byte reply. Owner сверяет digest до readiness callback и filesystem ACK.
- Отсутствующая запись или старый reply не подтверждают audit handoff. Повреждённая запись не означает ordinary fallback.
- После Continue candidate повторно проверяет запись/root, затем передаёт только изоляцию в app startup. Нет наследования fingerprint signer, challenge, baseline или qualification.
- Manager audit proxy credentials хранятся только в памяти, без legacy migration; backup composition unavailable. Это не проверка сохранения proxy passwords.
- Chromium в аутентифицированном release-audit и его продолжении получает native `--use-mock-keychain`. Обычный Release startup не получает этот флаг по имени временного каталога, argv, Info.plist или MCP. Отдельный capability создаётся до ProfileStore и удерживает приватный root/parent.
- Перед exec выбранный BrowserData должен находиться под закреплённым manager-data. Вся цепочка каталогов открывается с nofollow, проверяется на mode0700, UID, ACL/flags и повторно сверяется через parent→child entries. Descriptors имеют CLOEXEC и удерживаются через старт процесса. Это проверка custody, не filesystem sandbox против произвольного процесса того же пользователя после последней проверки.
- Только audit fingerprint reservations создаются в `manager-data/FingerprintAuditSessions`; существующий обычный путь сохранён. Foundation переписывает существующий `/private/tmp` в `/tmp`; custody сохраняет исходный nofollow path и сравнивает reservation aliases отдельно от проверки доступа.
- Обычный no-audit NUI1 и bootstrap reply остаются совместимыми. Оба будущих подписанных кандидата должны содержать один и тот же обновлённый owner helper; старые immutable assets не меняются.

## Проверки и ограничения

Локальные controls покрывают сохранение inode, замену root/parent, symlink, hardlink, mode, ACL, flags, изменённую/обрезанную запись, неверный request, init/offer binding и manifest limits. Реальный дочерний процесс со старым reply отказывается до readiness/commit и завершается под контролем родителя.

Дополнительные локальные controls покрывают фактический argv собственного fake executable: ordinary, audit normal и audit fingerprint. После final pre-exec refusal executable не запускается, provisional lease удаляется. Замена открытого промежуточного каталога обнаруживается, даже если root не менялся. Initial report parent должен быть приватным0700 — это также существующий контракт настоящего release-context loader; injected unit context не считается прохождением loader.

Эти проверки не заменяют exact signed/notarized old→new, реальный GUI restart, фактическую изоляцию Chromium Safe Storage, browser cookie/LocalStorage/IndexedDB/tab persistence и rollback. Native mock storage wiring реализован в source; qualified signed browser experiment ещё требуется. Включение updater требует собственного доверенного pinned manifest key/channel и всех Direct release gates. Сертификат Developer ID и runtime в этом source-срезе не изменялись.

## Владение временным каталогом fingerprint-проверки

Подтверждённый отрицательным контролем дефект: обычный резерв принимал свой pathname после замены каталога на symlink. Теперь менеджер удерживает parent/data descriptors и исходные inode; проверяет их до подготовки lease и перед exec. Захват сохраняет custody до конца очистки и освобождает неиспользованный резерв при любом выходе. Очистка сверяет identity, проверяет nofollow tree и удаляет через parent FD. Подменённый каталог или дерево с unsafe entry сохраняется, а не удаляется по устаревшему пути. Это защита локальной проверки, не обещание filesystem sandbox.
