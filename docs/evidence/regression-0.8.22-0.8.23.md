# Сравнение NeAntik 0.8.22 (134) → 0.8.23 (135)

Сводка опубликованных отчётов. Она не запускает браузер и не заменяет проверку релиза.

## Что изменилось

- Если известны адрес и порт прокси, нажмите **«Определить тип без пароля»** в редакторе профиля. NeAntik попробует HTTP и SOCKS5, не передавая логин и пароль.
- Найденный тип применяется отдельной кнопкой. Вставка строки сама по себе не отправляет запросов и не сохраняет профиль.
- Исправлена подсказка, которая после выбора SOCKS5 могла продолжать показывать HTTP. Изменение адреса и отмена убирают старый результат проверки.

## Runtime и условия сравнения

SHA-256 основного исполняемого файла Chromium и исполняемого файла Framework совпадают.
Полный инвентарь runtime здесь не сравнивается. Совпадение хешей не доказывает одинаковое поведение.
В исходных записях не хватает сведений об условиях измерения.
Вывод об отсутствии поведенческих регрессий не установлен. Производительность не измерялась.

## Состояние проверок в исходных отчётах

| Проверка | До | После |
| --- | --- | --- |
| Нотарификация | есть описание, без вывода PASS | есть описание, без вывода PASS |
| Stapling | есть описание, без вывода PASS | заявлен PASS |
| Gatekeeper | есть описание, без вывода PASS | заявлен PASS |
| Direct doctor | заявлен PASS | есть описание, без вывода PASS |
| Установка обновления | есть описание, без вывода PASS | есть описание, без вывода PASS |
| Откат | нет однозначного результата | нет однозначного результата |
| Запуск локальной подписанной сборки | есть описание, без вывода PASS | открыта |
| Запуск скачанной копии | нет однозначного результата | нет однозначного результата |
| MCP подписанного кандидата | нет однозначного результата | нет однозначного результата |
| MCP скачанной копии | есть описание, без вывода PASS | есть описание, без вывода PASS |
| Публичный ZIP | есть описание, без вывода PASS | есть описание, без вывода PASS |
| Публичный DMG | заявлен PASS | заявлен PASS |
| Сайт | есть описание, без вывода PASS | есть описание, без вывода PASS |

## Тесты, указанные в отчётах

Число reported-тестов включает явно пропущенные проверки. Эти записи не являются новым прогоном.

| Набор | До | После |
| --- | --- | --- |
| Swift | Full1651/194 included71 skips and one obsolete acceptedQuit state expectation; corrected only expected closing,119/7 affected PASS; original FAIL retained, no full repeat. | Full1673/200 and focused82/6 each failed only unchanged aggregate import budget7.5658/7.4065; original exact method isolated PASS1.5781s with same5s criterion. New detector/editor passed; diagnostics2.0349/1.6051. Aggregate failures retained, precise preceding-test influence unresolved. |
| Python | Full1648/19skip had3 missing-development-changelog errors; honest draft entry added and5/5 related documentation controls PASS; original FAIL retained, no full repeat. | Full run stopped after11min in unchanged provenance family,NOT PASS. Reviewed closed reader union:85related Python+30planner+2Python/17JSspeech+11inventory controls PASS; unknown fallback and release gates preserved. |
| Harness | не указан | не указан |
| site | не указан | не указан |

## Ограничения

- Public alpha; mandatory1.0 remains open.
- HTTPS/ambiguous no-authHTTP selected manually; discovery is not auth/internet/route proof.
- WebKit remains preview with production proxy disabled; not Safari fingerprint substitution.
- Aggregate import benchmark failures retained despite fresh exact-method PASS; cumulative-suite cause open.
- Qualified environment is macOS27 ARM64 only; other hardware/OS not proven.
- Runtime backport scope retained; Safe Browsing disabled; no universal undetectability.
- Site/feed update remains separately blocked.

Исходные записи: [v0.8.22.json](../../releases/v0.8.22.json), [v0.8.23.json](../../releases/v0.8.23.json)
