# Обновление NeAntik: интерфейс и границы

В кандидате 0.7.33/build96 команда **Обновить NeAntik…** открывает инструкцию ручной установки и ссылку https://browser.free/#download. Сначала закрываются браузерные окна и manager; затем новое приложение переносится в «Программы». Каталоги профилей не удаляются. Старые неизменяемые release assets сохраняются для отката.

## Подготовленный автоматический путь

Канал `NeAntikUpdateChannelEnabled` остаётся выключен. Наличие интерфейса или helper не означает готовую установку. При будущем включении используется только оригинальный ZIP и подписанный manifest того же выпуска; DMG и обычный SHA-256 файл не являются этим контрактом.

Контроллер принадлежит приложению, а не временному View. Он получает допуск до первого await, запрещает новые операции с профилями и держит допуск до подтверждённого завершения отмены. При неизвестном результате cleanup требуется выход из приложения. После consent/handoff приложение завершает работу; это ещё не доказательство успешной установки. Отдельный owner выполняет свежую проверку процессов, транзакцию, bootstrap нового кандидата и rollback.

Рабочие операции удерживают свои activity tokens до завершения настоящих workers, rollback и публикации состояния. Удаление Task из словаря или закрытие sheet не считается завершением. Это охватывает refresh/import, stopped-profile maintenance/restore, startup cleanup, backup/recovery, extensions/cache и proxy health persistence. Полная native inventory остаётся независимой обязательной проверкой.

## Проверено локально

- 11 новых targeted тестов: stale/duplicate tokens, реальные metadata операции и отмена import, реальное сохранение/rollback proxy health, повторные клики, удержание fence до drain, unknown cleanup, автоматический drain и commit без отмены.
- Чтение manifest ограничено128KiB; symlink, FIFO и oversized файл отказывают. FIFO открывается nonblocking, чтобы чтение не зависало до проверки типа.
- Полный релевантный прогон1372/159;52 opt-in declarations пропущены. Kernel/socket отказы sandbox устранены запуском в разрешённом контексте; критерии не ослаблены.
- Dev.app: новый синтетический каталог, readable manual sheet, Tab/Escape, Cmd-N, два Return (завершение редактирования → Create/Save), запуск/остановка, kernel absence собственного manager после меню Quit и metadata после повторного запуска.

Эти результаты не подтверждают автоматическую установку подписанного публичного кандидата. Обязательные открытые gates: легитимный pinned channel key/manifest feed, exact compatible notarized old→new, headed GUI/bootstrap, synthetic cookies/LocalStorage/IndexedDB/tabs и rollback без production data. Ни production Keychain, ни пользовательские профили не использовались.
