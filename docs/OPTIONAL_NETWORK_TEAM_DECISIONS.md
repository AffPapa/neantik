# WireGuard и командная работа: решение для плана 1.0

Проверено 14 октября 2026. **Эти функции в NeAntik не реализованы.** По пунктам
29 и39 принято исследовательское решение об отсрочке с условиями возврата.
Оно не закрывает обязательные проверки сети, backup, updater и релиза.

## WireGuard на профиль

В текущем продукте доступны HTTP, HTTPS и SOCKS5-прокси; WireGuard-зависимости
и Network Extension target в `Package.swift` отсутствуют. Идентификатор профиля
разделяет данные браузера и локальную relay-сессию. Он не является отдельной
подписью приложения для системной VPN-политики.

Apple сопоставляет per-app VPN с идентификатором подписи, designated requirement
и, при необходимости, путём/helper. Поэтому такая политика сама по себе не
выбирает UUID профиля в нашем общем runtime. Это вывод для текущей архитектуры,
а не утверждение о невозможности любых других решений.
[Apple app mapping](https://github.com/apple/device-management/blob/release/mdm/profiles/com.apple.vpn.managed.appmapping.yaml).

Для Direct Distribution Apple допускает Network Extension provider в виде
system extension. У обычного macOS app extension в таблице packet tunnel стоит
ограничение App Store; этот вариант не входит в наш workflow. System extension
потребует отдельной проверки подписи, entitlement, provisioning и активации.
Новых сертификатов или системных разрешений сейчас не создаём.
[Apple TN3134](https://developer.apple.com/documentation/technotes/tn3134-network-extension-provider-deployment).

| Вариант | Решение |
| --- | --- |
| Системный VPN | Не обещает независимую сеть каждому профилю; не менять системные маршруты автоматически. |
| Userspace helper на профиль + loopback relay | Следующий изолированный прототип: TCP/DNS через собственный WireGuard peer; полное покрытие UDP/IP ещё нужно доказать. |
| System extension с распределением flows | Отдельный вариант, требующий проверяемого сопоставления дочерних процессов профилям и полноценного установочного цикла. |

WireGuard предоставляет встраиваемые компоненты, но наличие библиотеки не
решает маршрутизацию профилей. Перед возможным заимствованием закрепить revision,
LICENSE/NOTICE и весь dependency graph; AGPL helpers Fury в продукт не копировать.
[WireGuard embedding](https://www.wireguard.com/embedding/).

**Возвращаемся к реализации после выбора сценария и прототипа.** Приёмка:
два профиля с разными peers; IPv4/IPv6, DNS, TCP и UDP по отдельности; внешний
WireGuard UDP transport отдельно от browser UDP; MTU/PMTU и большие передачи;
sleep/wake, reconnect и совместимость системного VPN; отказ peer/helper,
отмена, manager crash и PID reuse без Direct fallback; независимое завершение
соединений, лимиты ресурсов и exact signed qualification. Ключи передавать через
защищённый IPC/Keychain, исключая argv, логи и публичные отчёты.

## Self-hosted team

Текущие локальные revision/leases и MCP не являются распределённым сервером
с доступом нескольких пользователей. Локальный backup также не заменяет
распределение ключей и блокировки между Mac. Командный режим откладываем до
выбора инфраструктуры и отдельного продуктового решения.

Проект будущего слоя:

- Opt-in TLS service, транзакционная БД и object storage; device identity/private
  key в Keychain. Сервер не получает plaintext BrowserData или профильные ключи
  по умолчанию. Ключ профиля отдельно оборачивается для каждого допущенного устройства.
- Owner/admin/editor/operator/viewer получают права на project/profile; доступ
  к secrets выделен отдельно. Одни и те же проверки применяются к UI/API/MCP.
- Перед snapshot профиль закрывается. Живые SQLite не объединяются. Server
  lease/TTL и монотонный fencing token исключают запись устаревшего владельца.
  Immutable upload → проверка целостности/durability → CAS manifest.
- Idempotency, recovery и отложенный GC; offline/stale commit отклоняется,
  локальная divergence сохраняется и показывается в интерфейсе.
- Revoke запрещает будущий доступ и ротирует будущие ключи. Уже скачанный
  plaintext отозвать невозможно. Backup БД/ciphertext и key recovery проверяются
  отдельно; переносимость macOS-encrypted авторизации не обещается.
- Audit journal хранит минимальные actor/action/result/revision без cookies,
  паролей, токенов и содержимого страниц.

Транзакции, encryption и условная публикация — разные механизмы:
[PostgreSQL isolation](https://www.postgresql.org/docs/current/transaction-iso.html),
[CryptoKit](https://developer.apple.com/documentation/cryptokit),
[conditional writes](https://docs.aws.amazon.com/AmazonS3/latest/userguide/conditional-writes.html).
Конкретный cryptographic protocol и совместимость object store ещё не выбраны.

**До включения team mode:** два тестовых Mac; concurrent edits, partition,
clock skew, TTL/fencing; crash между upload/publish; повреждение, перестановка
и replay chunks; запрет чужих projects/profiles; revoke/key loss/server restore;
conflict UI, backup recovery и одинаковые UI/API/MCP boundaries. Проектирование
не объявляется работающей функцией, и инфраструктура сейчас не развёртывается.
