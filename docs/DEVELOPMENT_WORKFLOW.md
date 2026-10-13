# Короткий цикл разработки NeAntik

## Обычная правка

1. Прочитать CURRENT/checkpoint и выбрать одну изменяемую поверхность.
2. Получить read-only план через `python3 -B scripts/plan-manager-checks.py --base HEAD`, проверить зависимости и запустить связанные наборы одной командой, например:

   ```bash
   python3 -B scripts/test-manager-fast.py --suite ProxyImportParserTests --suite BrowserRouteProbeTests
   ```

3. Для видимого изменения открыть `./Develop-NeAntik.command --fixture`.
   Не создавать новый bundle на каждую проверку. Не подменять запущенную копию.
4. После интеграции выполнить один `--all`, затем необходимые exact release gates.

`--list` автоматически получает имена наборов из текущих Swift-файлов.
`--plan` показывает выбор без сборки/Keychain. Неизвестный набор, regex во
входном имени, нулевое число тестов или изменение исходников во время прогона
дают отказ. Кэш тот же, что у локальной manager-сборки; SwiftPM пересобирает
изменённые зависимости. Сами тесты исполняются каждый раз: cached build не
означает cached PASS. Fast tests и Dev build/package используют общую lease физического кэша. Конкурирующая команда получает exit75; SIGTERM/SIGINT отменяют свою child process group и дожидаются settlement. Это координация наших wrappers, не глобальная блокировка всех компиляторов на Mac.

## Что замедляло работу

- Старые suite/full wrappers каждый раз создают временный scratch-каталог и
  удаляют его после теста. Сохраняем их для чистого прогона, а ежедневный цикл
  использует постоянные project-owned caches.
- Ручной список наборов устаревал после появления новых классов. Fast runner
  получает каталог из исходников; пустая выборка не может стать PASS.
- Запуск одной сборки на каждый suite. Несколько `--suite` дают один вызов SwiftPM.
- Нативная проверка повторялась после ошибки только анализатора. Сохранять
  execution receipt и приватный trace до анализа, затем исправлять анализ
  офлайн на тех же байтах с отрицательными контролями.
- Старые pending из накопленного state возвращали закрытые задачи.
  Один CURRENT показывает оставшуюся работу и принятые ограничения.

## Релиз и обновления

- Сначала один законченный срез, затем один source-bound кандидат.
- Сохранять receipt каждой дорогой стадии: source/build, signed app,
  fingerprint, ZIP, Apple transaction ID, stapling, DMG, hosted bytes, Site.
- Сбой локального продолжения после Apple Accepted не требует новой отправки:
  `notarize_direct_transaction.py` уже поддерживает проверенное продолжение
  известной транзакции. Использовать существующий ZIP-transaction workflow.
- DMG packaging пока не имеет эквивалентного автоматического resume:
  не запускать весь `Release-NeAntik.command` повторно, когда нужна только
  диагностика уже принятого DMG. Доработка DMG resume — отдельный срез с
  fault tests, а не ручное ослабление hash/signing/notary gates.
- Не заменять опубликованные assets и не выпускать app заново ради поправки
  разработческих команд. GitHub/Site публикация должна следовать реальным байтам.

## Проверенный пример

13 октября 2026: два выбранных набора, **30 тестов / 2 suites**, cached native
build + исполнение заняли **0,712 с** на текущем Mac. Проверка актуальности
QA-менеджера: native build **0,28 с**. Это отдельные измерения тёплого кэша,
не обещание такой скорости clean build, полного suite или notarization.
Jobs остаются2: это ограничение нагрузки, не исправление причины kernel panic.

Подробный лог/receipt хранится локально в `.build/neantik-local/test-receipts`;
обычный вывод содержит короткий итог, не весь compiler/test transcript.
Публичная команда не читает секреты и не запускает signing/notarization/deploy.

Итог Swift Testing включает отключённые тесты. Receipts отдельно показывают
строки реально прошедших и пропущенных тестов; вывод только со skipped-тестами
отклоняется. Benchmark импорта5000 профилей сохраняет прежние count/time
assertions и требует inherited NOFILE и kern.maxfilesperproc>=16024. Если
ёмкость меньше или не удалось её прочитать, benchmark явно пропускается;
системные лимиты для него не повышаются. Такой CI не
подтверждает производительность этого benchmark — нужен отдельный реальный
проход на машине с достаточной ёмкостью.

## CI и выбор проверок

- Resolver проверяет реальный импорт и typecheck публичных SDK API менеджера
  для ARM64/macOS14, Swift5 language mode, compiler не ниже Swift6.2.
  Различие build-номеров compiler и SDK само по себе допустимо при module
  stability. Explicit DEVELOPER_DIR не заменяется другой установкой при отказе.
  Probe не линкует и не запускает приложение; полный build/tests остаются
  отдельными проверками. Проверка локально занимает около3с, поэтому это
  дополнительное время к ранее измеренному тёплому native run.
  Каждый typecheck имеет срок60с и собственный временный module cache;
  после отмены supervisor завершает свою process group до освобождения lease.
- `workflow_dispatch` с `toolchain_probe=true` выполняет только эту диагностику.
  Она не означает PASS тестов приложения и позволяет исправить setup до
  повторного запуска четырёх сборочных групп.
- Четыре чистых CI shards вместо148сборочных jobs. Каждый shard строит общий target в собственном cache и запускает suites последовательными отдельными процессами. Между CI jobs/runs кэш не переносится. Native execution обоих labels и code paths не заменяется Python mock.
- Каталог следует реальным типам Swift, включая несколько suites в одном файле и extensions существующей suite. Вложенные файлы включены. Неподдержанная unscoped @Test declaration даёт отказ; wholly opt-in и Live suites исключены из обычного CI. Mixed QA flags/data-root overrides удаляются из child environment.
- Plan-manager-checks показывает команды и дополнительные gates, но ничего не запускает. Rename/delete/untracked входят в diff; неизвестные/shared inputs требуют full regression. Карта рекомендаций не заменяет анализ зависимостей.
- Workflow changes проверяются targeted Python contracts и одним достаточным реальным native integration. Новая сборка приложения не нужна для правки instructions/check planner.
- После завершения среза записать в CURRENT один следующий шаг; накопленный state остаётся историей. Большие manifests читать по нужным полям.

## Правила для процесса агента

Не подключать skill/MCP ради количества. Project implementation workflow находится в `.agents/skills/neantik-development/SKILL.md`; runtime audit загружается только для нужного runtime scope. AGENTS хранит короткие неизменные границы, workflow — skill/scripts, история — receipts/memory router. API cache knobs не являются настройками desktop; модель, reasoning, permissions и credential scope не меняются ради недоказанного ускорения.
