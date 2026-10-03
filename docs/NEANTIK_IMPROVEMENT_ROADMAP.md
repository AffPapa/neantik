# NeAntik: roadmap улучшений

Дата ревизии: 25 сентября 2026 года.

Цель roadmap — сделать NeAntik быстрым и понятным локальным браузером для
профилей, сохранив defensive-границы: тестируем только собственные стенды и
синтетические fixtures, не собираем чужие fingerprint-данные и не обещаем
обход сторонних антифрод-систем.

Статусы:

- `done` — реализовано в manager/runtime-evidence pass и покрыто проверками;
- `next` — можно делать без пересборки Chromium;
- `runtime-gate` — требует точного runtime source/binary provenance и полного
  GUI/security/release evidence cycle;
- `defer` — сознательно не входит в компактный Direct-продукт.

## Manager-only срез 3 октября 2026

Кандидат 0.7.13/76: быстрые команды, пользовательские безопасные шаблоны,
сохранённые фильтры, revision-safe Undo metadata, ограничение одиночных запусков
и локальный ограниченный журнал реализованы и проверены локально. Batch UI отложен.
Исправлено штатное закрытие browser для сохранения буферизованных persistent data.
Публичный статус определяется `SOURCE_TO_SITE_HANDOFF.md`, а не этой строкой.
G/H отложены: критерии восстановления в `MANAGER_RECOVERY_BACKUP_DESIGN.md`.

## Приоритетный список

| № | Улучшение | Приоритет | Статус | Что считается готовым |
|---:|---|:---:|:---:|---|
| 1 | Быстрое создание профиля с разумными defaults | P0 | done | Пустое рабочее пространство предлагает одно действие «Создать и открыть», а расширенные поля остаются отдельным сценарием. |
| 2 | Единая карточка «Диагностика» | P0 | done | Lifecycle, privacy, provenance и recovery не дублируются на главном экране. |
| 3 | Безопасный статус запуска | P0 | done | Статусы запуска сведены к готовности, проверке, запуску, остановке и конкретному восстановлению; внутренние lease-фазы не выводятся. |
| 4 | Crash-safe launch и восстановление | P0 | done | Lock, recovery и неполный запуск не маскируются под успешный запуск. |
| 5 | Атомарный импорт профилей по папкам | P0 | done | Частичный импорт не оставляет смешанные или потерянные профили. |
| 6 | Локальные snapshots с понятным rollback | P1 | done | Metadata-only snapshot/restore доступен из меню, хранит последние 3 версии, восстанавливает новые identity и fail-closed отклоняет повреждённый файл. |
| 7 | Копирование профиля как безопасный шаблон | P1 | done | Дублирование создаёт новую identity, очищает note/launch state и не копирует BrowserData или Keychain-секрет. |
| 8 | Поиск, теги и папки без перегрузки панели | P1 | done | Частые операции остаются на первом уровне, редкие — в меню. |
| 9 | Импорт/экспорт через системный file dialog | P0 | done | Пользователь выбирает файл обычным macOS-диалогом; секреты и BrowserData исключены. |
| 10 | Aggregate privacy-панель media/permissions | P0 | done | Только безопасные состояния, без device IDs и сырых значений. |
| 11 | Презентация маршрута без реального IP | P0 | done | В интерфейсе остаётся только «Маршрут подтверждён» и контекст проверки. |
| 12 | Свежая проверка маршрута перед proxy launch | P0 | done | Старая ручная проверка не превращается в бессрочное разрешение. |
| 13 | Extension/download provenance и quarantine | P0 | done | Неизвестный артефакт не активируется автоматически; источник и решение видны явно. |
| 14 | Понятный центр разрешений | P1 | done | В карточке диагностики разрешения сгруппированы по профилю и действию; показываются только aggregate states, без скрытого глобального allow и сырых device IDs. |
| 15 | Manager performance budgets | P0 | done | Есть p50/p95 budgets для 1/50/100 профилей; manager-метрики не выданы за Chromium-метрики. |
| 16 | Runtime performance contract | P0 | done | Privacy-safe verifier с cold/warm, idle CPU/RAM и fail-closed `--require-verified`. |
| 17 | Production runtime measurement | P0 | runtime-gate | Нужны точный runtime hash, квалифицированный producer, GUI smoke и release binding. |
| 18 | Compact runtime provenance card | P0 | done | Версия, подпись и хэши показываются безопасно; неполный provenance не выглядит готовым. |
| 19 | A → B → A только по явному инженерному действию | P0 | done | Обычный запуск и recovery не порождают скрытых браузерных проверок. |
| 20 | Synthetic fingerprint corpus для своих стендов | P0 | done | Положительные и негативные fixtures, leak mutation и отсутствие реальных пользовательских данных. |
| 21 | Readiness gate для A → B → A | P0 | done | Проверка запускается только для двух разных реально остановленных профилей. |
| 22 | Ограничение и privacy-cap raw reports | P0 | done | Не более трёх owner-only файлов и не более 512 KiB каждый до записи. |
| 23 | Безопасная сводка вместо raw evidence в UI | P0 | done | В обычном результате только verdict; raw JSON доступен лишь в явном engineering-контексте. |
| 24 | Клавиатурная навигация | P1 | earlier limited Dev.app keyboard check recorded; repeat and exact-candidate QA pending | Ранее записаны Tab по форме создания профиля, Escape/cancel, ⌘N, ⌘⇧N и ⌘F; возврат фокуса и Return отдельно не проверены. При повторной попытке 25 сентября Dev.app не дошёл до UI из-за Development-данных неверного формата; данные не восстанавливались и не менялись. App-issued speech announcements удалены в `66c590b`; SwiftUI accessibility tree скрыт в `b23b4b9` по решению владельца. Статические source-contract тесты не заменяют физическую клавиатурную проверку. Для snapshot/import/export/support bundle остаётся видимый временный статус. Публичный 0.7.11 описывает историческое поведение. |
| 25 | Redacted crash/support bundle | P1 | done | Экспорт содержит только allowlisted enums/версии/хэши, ограничен 64 KiB, проходит независимый fail-closed verifier и доступен через системный Save dialog. |
| 26 | Signed runtime update с rollback | P1 | runtime-gate | Проверяются подпись, provenance, атомарная замена и восстановление предыдущего runtime. |
| 27 | Полный release evidence bundle | P0 | runtime-gate | Source lock, binary hash, signing, notarization, stapling, Gatekeeper, fresh download и live smoke согласованы. |
| 28 | Read-only локальный diagnostics adapter | P2 | defer | Возможен только явно включаемый loopback с auth и тем же allowlisted snapshot; API запуска/изменения профилей не добавляется. |
| 29 | Background-request inventory Chromium | P1 | runtime-gate | Сначала измерение точного runtime, затем отдельное решение по phishing/safe-download policy. |
| 30 | Командная автоматизация, облачная синхронизация и RPA | P2 | defer | Сознательно не добавлять: они раздувают продукт и расширяют privacy/security surface. |
| 31 | Next-step UX для карточки «Диагностика» | P1 | done | Для attention/unavailable показывается одно короткое следующее действие; ready остаётся тихим, raw значения не раскрываются. |
| 32 | Компактные шаблоны нового профиля | P1 | done | Шаблоны предлагают только редактируемые имя и тег в существующей форме; остальные runtime defaults не меняются. |
| 33 | Локальная сводка browser-feature availability | P1 | done | Отчёт привязан к свежему точному профилю/runtime, session-only, скрывает raw values и не утверждает совместимость конкретного сайта. |
| 34 | Локальная read-only release-gate summary | P1 | done | CLI разделяет source binding, текущий candidate gate и исторические release claims; не читает credentials и raw evidence. |
| 35 | Rehearsal retained Direct artifacts | P2 | shipped in 0.7.9 | ZIP/DMG v0.7.8 проверены по release evidence и повторным SHA-256 в staging; это не install/launch или hosted rollback smoke. |
| 36 | Локальное руководство профилей и recovery | P2 | shipped in 0.7.9 | Bilingual guide объясняет profile data, metadata-only snapshot, новые identity после restore и различие plain/encrypted transfer; ссылка добавлена в оба README. |
| 37 | Предварительный просмотр snapshot restore | P1 | shipped in 0.7.10; progress state added in local commit `66c590b` | До commit показываются безопасные aggregate counts и дата; cancel не меняет store, working-profile guard и store transaction остаются обязательными. Повторное нажатие блокируется во время записи, а успешное восстановление даёт видимый короткий статус. Публичный 0.7.11 исторически добавлял речь; commit `66c590b` удаляет app-issued announcement. |
| 38 | Фоновый preview bulk proxy import | P2 | implemented/tested locally; Direct release blocked by Chromium baseline | Debounced/cancellable parse выполняется вне MainActor, старый preview не может быть отправлен; лимиты и privacy-safe ошибки сохранены. Для публичной версии нужен разрешённый runtime update и полный runtime gate cycle. |
| 39 | Фоновая транзакция импорта профилей и папок | P1 | implemented/tested locally in `66c590b`; Direct release blocked by Chromium baseline | Полный disk reload/recovery/validation, создание каталогов и запись metadata идут вне MainActor под flock; shared fail-fast gate защищает все окна store; успех публикуется после завершения worker, а ошибка заново сверяет disk recovery/normalization с открытым UI либо fail-closed блокирует store. 5 000 профилей с 5 000 уникальными папками прошли debug benchmark; время зависит от устройства. |
| 40 | Отличать лимит подсчёта BrowserData от ошибки доступа | P2 | implemented/tested in `29b4325` | Превышение лимита файлов/байтов показывает «Лимит проверки достигнут», symlink и ошибки чтения остаются «Проверка недоступна»; тесты задают маленький лимит на временном каталоге вместо создания огромного профиля. |

## Следующие незакрытые действия

1. Перед Direct-релизом повторить физическую клавиатурную проверку на пригодном
   Dev.app, затем на exact candidate: Tab order, focus return, Escape, Return,
   ⌘N, ⌘⇧N и ⌘F. Ранее записанный ограниченный smoke не привязан к source hash;
   повторный запуск 25 сентября не дошёл до UI из-за неверного формата
   Development-данных. Данные не восстанавливались и не менялись.
2. До любых изменений профилей выполнить отдельный threat review repair
   assistant. Сейчас безопасная автоматическая recovery и read-only notice уже
   реализованы; новая функция может затронуть пользовательские metadata и
   поэтому не считается готовым manager-only quick win.
3. Закрыть runtime-gated evidence только на точном Chromium/runtime candidate.
   Preflight выбирает source contract по major-версии runtime lock; текущему
   runtime 153 всё ещё не хватает соответствующего contract, а Chromium ниже
   обязательного baseline 154. Этот аудит не менял и не пересобирал Chromium.
4. Для публикации через AffPapa восстановить credential для
   `neantik-affpapa-release doctor`; текущая проверка завершилась ошибкой
   `deploy credential is unavailable`. Это блокирует только AffPapa workflow,
   а не GitHub Release или browser.free.

После v0.7.11 все ранее перечисленные manager-only roadmap features
реализованы. Фоновый preview bulk proxy import реализован и прошёл локальные
тесты; пакетное создание папок также прошло локальный performance test.
Изменения не вошли в публичную бинарную версию: Chromium 153 ниже текущей
security baseline 154.0.8037.58. Не считать partial runtime report
доказательством runtime readiness.

## Что не является целью

NeAntik не будет скачивать реальные fingerprint-профили из интернета,
подменять значения случайным шумом, собирать чужие cookies/ICE/IP или
встраивать логику обхода CAPTCHA, банов, антифрода и правил сторонних сайтов.
Для проверки собственной защиты используются только синтетические fixtures,
контролируемые тестовые страницы и измерения, которые не содержат
идентифицирующих значений.
