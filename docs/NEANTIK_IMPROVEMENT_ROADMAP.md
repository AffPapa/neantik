# NeAntik: roadmap улучшений

Дата ревизии: 24 сентября 2026 года.

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
| 24 | Клавиатурная и VoiceOver-навигация | P1 | done (automated); physical QA pending | Основные действия и restore preview имеют keyboard shortcuts, labels/hints и presentation tests. Проход реального VoiceOver и физической клавиатуры на рабочем Mac не подтверждён автоматическими тестами. |
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
| 37 | Предварительный просмотр snapshot restore | P1 | shipped in 0.7.10 | До commit показываются безопасные aggregate counts и дата; явное подтверждение, cancel не меняет store, working-profile guard и store transaction остаются обязательными. |

## Что делать следующим без пересборки Chromium

1. Выпустить manager-only preview после exact-source Direct gates; Chromium
   остаётся неизменным.
2. Проверить клавиатуру и VoiceOver на реальном Mac после automated UI gates;
   не выдавать presentation tests за физическую проверку.
3. Рассмотреть explicit profile-integrity repair assistant только после
   отдельного threat review; любые исправления должны быть opt-in, атомарными
   и с проверяемым rollback.
4. Повторять Swift gate, privacy/public-artifact audit,
   `git diff --check` и локальный audit; partial runtime report не становится
   release evidence.

## Что не является целью

NeAntik не будет скачивать реальные fingerprint-профили из интернета,
подменять значения случайным шумом, собирать чужие cookies/ICE/IP или
встраивать логику обхода CAPTCHA, банов, антифрода и правил сторонних сайтов.
Для проверки собственной защиты используются только синтетические fixtures,
контролируемые тестовые страницы и измерения, которые не содержат
идентифицирующих значений.
