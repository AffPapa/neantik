# Публичный fingerprint conformance corpus

NeAntik публикует синтетический набор отчётов, который проверяет границу между
`public-alpha-qualified`, `production-qualified` и подтверждённым отказом.
Это regression corpus для разработчиков и внешнего аудита, а не доказательство
конкретного релиза.

Запуск:

```bash
./scripts/verify-public-fingerprint-corpus.py
```

Corpus находится в:

```text
Tests/Fixtures/fingerprint-conformance/
├── base-production-qualified.json
└── manifest.json
```

Базовый schema 7 report содержит только документированные синтетические
UUID, имена, identity codes, значения поверхностей и фиктивные SHA-256.
`manifest.json` применяет небольшой allowlist мутаций и фиксирует ожидаемый
результат:

- полная строгая квалификация;
- public alpha PASS при рассогласовании main realm и Worker;
- public alpha PASS при недоступной или расходящейся Worker device memory,
  которая блокирует только строгий production;
- public alpha PASS при стабильной, но внутренне противоречивой паре
  `navigator.languages`/`Intl.locale`, которая блокирует строгий production;
- нестабильный Canvas;
- диагностический, а не обычный browser mode;
- недоступная `deviceMemory`;
- прямой WebRTC candidate при объявленном proxied route.

WebRTC evidence хранит только тип и количество candidates, факт завершения ICE
и ограниченное число запросов к приватному loopback STUN responder. Строки
ICE, IP-адреса, hostnames, packet bytes, transaction IDs и их хэши в публичный
corpus и локальный report не попадают. `loopback-stun-v1` требует положительный
direct control в том же запуске и ноль STUN-запросов для proxied route.

Verifier выполняет настоящий `verify-gui-fingerprint-report.py`, а не
упрощённую копию правил. Дополнительно он отклоняет:

- неизвестные profile ID, profile name и identity code;
- proxy/password/username/cookie/history/seed-поля;
- локальные пользовательские пути и private-key markers;
- настоящие runtime hashes вместо синтетических sentinel;
- неразрешённые mutation paths;
- изменение ожидаемого PASS/FAIL-контракта.

Corpus никогда не создаётся из пользовательского
`~/Library/Application Support/NeAntik/FingerprintAudits` и не должен
заменять GUI A → B → A evidence. Для релиза по-прежнему нужен свежий отчёт,
снятый с точного подписанного runtime в обычной macOS GUI-сессии.

При расширении audit schema сначала добавьте отрицательный synthetic case,
затем измените verifier и только после этого обновляйте ожидаемый результат.
Нельзя ослаблять case ради зелёного gate.
