# Профили, приватность и восстановление

Это краткая памятка о том, что хранит профиль NeAntik и что можно вернуть
после ошибки. Snapshot и экспорт настроек — разные вещи; ни один из них не
является копией истории браузера.

## Данные профиля

Каждый профиль имеет отдельные постоянные данные браузера. Cookies, сайты,
local storage и другие данные браузерной сессии принадлежат этому профилю.
Пароль прокси хранится отдельно в Связке ключей macOS. NeAntik не требует
аккаунт или облако для работы.

Профиль можно найти по имени/тегу, перенести в папку, архивировать или
дублировать. Дубликат получает новую identity и отдельный каталог BrowserData;
сессия браузера не копируется.

## Локальный snapshot

В меню **Профили** выберите **Сохранить локальный snapshot**. Сохраняются
остановленные профили; работающие пропускаются, и приложение показывает оба
количества. Хранятся последние три snapshot.

Snapshot сохраняет настройки профилей и имена папок. Он не содержит BrowserData,
cookies, заметок, identity, fingerprint evidence или значений из Связки ключей.
Для восстановления выберите **Восстановить локальный snapshot…**. Все браузерные
профили должны быть остановлены. Восстановленные записи добавляются как новые
профили с новой identity и без браузерной сессии; исходные профили не заменяются.
Повреждённый или небезопасно расположенный файл отклоняется целиком.

После автоматического восстановления метаданных профиля или папок NeAntik
показывает в текущем запуске короткое уведомление. Оно описывает только
восстановление списка метаданных; данные браузера при этом не меняются.

## Перенос настроек

В меню **Профили** доступны обычный JSON и отдельный зашифрованный экспорт.
Оба переносят настройки и папки, но не BrowserData, cookies, заметки, identity,
fingerprint evidence или пароль прокси. Логин прокси включён: обычный JSON
содержит его открытым текстом, зашифрованный экспорт защищает его паролем.
Храни файл и пароль отдельно. Забытый пароль зашифрованного экспорта невозможно
восстановить.

Импорт создаёт новые профили и identity; он не открывает существующую сессию.
Подробные технические ограничения, включая требования к паролю и размеры
файлов, описаны в [формате переноса конфигураций](PROFILE_CONFIGURATION_TRANSFER.md).

Перед отправкой диагностики просмотрите назначение файла и получателя.
Безопасная диагностика — отдельный allowlist-отчёт, а не профиль и не backup.

---

# Profiles, privacy, and recovery

This guide explains what a NeAntik profile stores and what can be recovered.
A snapshot and a settings export are different; neither is a copy of browser
history or session data.

## Profile data

Each profile has its own persistent browser data. Cookies, websites, local
storage, and other session data belong to that profile. Proxy passwords are
stored separately in macOS Keychain. NeAntik does not require an account or
cloud service.

You can search profiles by name or tag, move them between folders, archive
them, or duplicate one. A duplicate receives a new identity and a separate
BrowserData directory; its browser session is not copied.

## Local snapshot

Choose **Profiles → Save local snapshot**. Stopped profiles are saved; running
profiles are skipped, and the app reports both counts. NeAntik keeps the latest
three snapshots.

A snapshot stores profile settings and folder names. It does not contain
BrowserData, cookies, notes, identity, fingerprint evidence, or Keychain values.
To restore, choose **Profiles → Restore local snapshot…**. All browser profiles
must be stopped. Restored records are added as new profiles with a fresh
identity and no browser session; existing profiles are not replaced. A damaged
or unsafe file is rejected as a whole.

If NeAntik automatically recovers profile or folder metadata, it shows a short
notice for the current app session. The notice describes metadata recovery only;
browser data is unchanged.

## Transfer settings

The **Profiles** menu offers plain JSON and a separate encrypted export. Both
transfer settings and folders, but exclude BrowserData, cookies, notes,
identity, fingerprint evidence, and the proxy password. The proxy login is
included: plain JSON stores it as readable text, while encrypted export
protects it with your passphrase. Keep the file and passphrase separately. A
lost encrypted-export passphrase cannot be recovered.

Import creates new profiles and identities; it does not reopen an existing
browser session. Technical limits, including passphrase and file-size rules,
are in [profile configuration transfer](PROFILE_CONFIGURATION_TRANSFER.md).

Review the purpose and recipient before sharing diagnostics. A safe diagnostic
export is a separate allowlisted report, not a profile or a backup.
