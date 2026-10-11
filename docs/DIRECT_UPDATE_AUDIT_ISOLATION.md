# Изоляция данных при квалификации updater

Статус: реализован source-контракт, локальные тесты. Полное обновление подписанного old → new через GUI ещё не квалифицировано. Публичный updater выключен.

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
- Обычный no-audit NUI1 и bootstrap reply остаются совместимыми. Оба будущих подписанных кандидата должны содержать один и тот же обновлённый owner helper; старые immutable assets не меняются.

## Проверки и ограничения

Локальные controls покрывают сохранение inode, замену root/parent, symlink, hardlink, mode, ACL, flags, изменённую/обрезанную запись, неверный request, init/offer binding и manifest limits. Реальный дочерний процесс со старым reply отказывается до readiness/commit и завершается под контролем родителя.

Эти проверки не заменяют exact signed/notarized old→new, реальный GUI restart, browser cookie/LocalStorage/IndexedDB/tab persistence и rollback. Для будущего браузерного эксперимента отдельно обеспечить временный user-data-dir и native mock Keychain; перенос manager root сам по себе не изолирует Chromium Safe Storage. Включение updater требует собственного доверенного pinned manifest key/channel и всех Direct release gates. Сертификат Developer ID и runtime в этом source-срезе не изменялись.
