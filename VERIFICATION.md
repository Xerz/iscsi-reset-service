# Verification record

## GitHub Release v0.4.4 — 2026-08-22

- Hotfix собран из commits `d72ee30` и `0aaef0e`; аннотированный tag `v0.4.4` указывает на
  `0aaef0e68a56819311e92e570d42cc95eefef93f`.
- Повторный branch CI run `32588611525` завершился success во всех jobs: Python/JavaScript,
  Compose interaction и Windows PowerShell 5.1. На Windows Pester 5.7.1 выполнил **55 passed,
  0 failed, 0 skipped** за 9.11 секунды.
- Tag publish run `32588787809` завершил validate, повторный полный verification и publish со
  статусом success; GitHub Release опубликован как
  `https://github.com/Xerz/iscsi-reset-service/releases/tag/v0.4.4`.
- Release содержит ровно семь ожидаемых assets: TrueNAS YAML, `image-digest.txt`,
  `SHA256SUMS` и четыре операторских `.ps1`. Скачанные заново файлы прошли
  `sha256sum --check SHA256SUMS`.
- Скачанный workflow artifact `iscsi-reset-service-v0.4.4-truenas` содержит те же семь файлов;
  каждый файл побайтно совпал с соответствующим GitHub Release asset, повторная checksum
  verification прошла.
- Bundle прошёл `docker compose config --quiet`, содержит два одинаковых image reference
  `ghcr.io/xerz/iscsi-reset-service@sha256:5da535dffc376222d6de1e0bebf818a151b79efbd6351a885c2ccdd0248219e7`,
  два management-IP placeholder и site-specific пути `/mnt/tank/...`.

Физическая перестановка автоматически назначенных букв на реальном Windows/TrueNAS стенде
после этого hotfix остаётся ожидающей проверки.

## Client installer и согласование drive letters v0.4.4 — 2026-08-22

Client installer больше не принимает raw token в аргументах и использует well-known SID для
ACL. Текущий рабочий набор дополнительно согласует автоматически назначенные Windows буквы
только внутри полного доказанного по NAA client-набора, ограниченно ждёт готовности
partition/volume metadata и пишет подробный локальный JSONL без token. Reset API, schema v3,
SQLite и параметры runtime-скрипта не изменялись.

### Операторские данные реальной Windows и TrueNAS

- Интерактивный installer из commit `879c28f` успешно завершился на русской Windows; скрытый
  token и IP были приняты, scheduled task создана. Точное содержимое итогового ACL отдельно не
  снималось.
- При отсутствии старых клонов первый запуск создал правильные ZFS clones, extent mappings и
  перевёл клиента `beast` на активный release в панели. После подключения Windows новая session
  отключалась на стадии локальной проверки дисков.
- Реальный `C:\ProgramData\IscsiReset\logs\reset.jsonl` четыре раза зафиксировал
  `disk_validation: Drive letter E: is occupied`. Отдельный `LOCAL_SESSION_ACTIVE` был
  намеренно вызван оператором и к дефекту не относится.
- Последующие подключения и переход на следующий release завершались; один диск визуально
  переподключался при автоматическом назначении букв. Проверка rollback реального клона также
  прошла: созданный клиентский файл исчез, чистый том подключился.

Это подтверждает server-side prepare/release/clone flow и локализованный installer, но ещё не
проверяет новое автоматическое согласование конфликтующих букв из текущего рабочего дерева.

### CI commit `879c28f`

- Python/JavaScript и Compose interaction jobs прошли.
- Windows PowerShell 5.1 job выполнил **34 tests successfully** и упал на одной новой ACL
  assertion: .NET возвращает `IdentityReference` как отображаемые имена
  `NT AUTHORITY\SYSTEM`/`BUILTIN\Administrators`, хотя правила были созданы из SID. Текущий
  тест переводит каждую identity обратно в `SecurityIdentifier` перед сравнением; production
  ACL-код не менялся.

### CI commit `d72ee30`

- Python/JavaScript и Compose interaction jobs прошли.
- Windows PowerShell 5.1 подтвердил исправление ACL assertion, но обнаружил вторую разницу
  тестовой среды: настоящий `Get-Partition` объявляет `DiskNumber` как `UInt32[]`, поэтому
  Pester передавал mock-функциям одноэлементный массив вместо scalar из Linux-заглушки.
- До выполнения letter logic успели пройти **45 tests**, а девять Windows reconciliation tests
  завершились одним и тем же test-only преобразованием `UInt32[]` в `Int32`; production-код в
  этих падениях не участвовал. Текущие mocks явно требуют ровно один disk number и извлекают
  его первый элемент.

### Локальные автоматические проверки текущего hotfix

- `ruff check .` — passed.
- `pytest -q --cov=iscsi_reset_service --cov-report=term-missing` — **133 passed**; release
  bundle regression по-прежнему покрывает все четыре операторских `.ps1`.
- `node --check src/iscsi_reset_service/static/app.js`,
  `node tests/static_connection_presentations.test.mjs` и `git diff --check` — passed.
- Все `.ps1` разобраны PowerShell parser из `mcr.microsoft.com/powershell:7.5-ubuntu-24.04` —
  syntax passed.
- Pester 5.7.1 в Linux PowerShell-контейнере — **54 passed, 1 skipped**. Проверены правильные,
  свободные и переставленные `E/F`, внешний владелец, wrong/extra NAA, read-only, лишние
  partitions, label mismatch, metadata retry/timeout, partial assignment, итоговая сверка,
  этапы JSONL и отсутствие token. Пропущен только настоящий Windows ACL object test.
- `docker compose config --quiet` — passed.
- `docker compose up --build --abort-on-container-exit --exit-code-from
  windows-simulation` — passed на локальном arm64 Docker host. Оба application containers
  сообщили version `0.4.4`; итог — `Interaction suite passed`. Затем выполнен
  `docker compose down --volumes`.

Windows PowerShell 5.1 CI и физическая перестановка автоматически назначенных букв остаются
ожидающими следующих отдельных шагов. Результат публикации tag и release assets фиксируется
отдельной записью после завершения release workflow.

## Один dual-role Publisher/client ПК v0.4.3 — 2026-08-22

В рабочем дереве schema v3 разрешает ровно одному client повторять полную пару
`publisher.source_ip + publisher.initiator_iqn` при обязательной отдельной target. Частичные
совпадения и второй shared client отклоняются. Контракты Reset API, SQLite и PowerShell не
изменялись. Изменения выпущены аннотированным tag `v0.4.3` из commit `c6b0f8b`.

### Локальные автоматические проверки v0.4.3

- `ruff check .` — passed.
- `pytest -q` на локальном Python 3.12 — **133 passed**. Покрыты schema, независимая проверка
  обеих target, неправильные и отсутствующие точные IQN/`/32`, сохранение config, блокировка
  client prepare при master session, блокировка stage/activation при client session, точная
  причина отказа activation и разрешение операций после отключения.
- `node --check src/iscsi_reset_service/static/app.js` и
  `node tests/static_connection_presentations.test.mjs` — passed. Ожидаемая активная вторая
  роль отображается предупреждением с target IQN, неизвестное частичное совпадение остаётся
  красным `identity conflict`.
- `docker compose config --quiet` и `git diff --check` — passed.
- `docker compose up --build --abort-on-container-exit --exit-code-from
  windows-simulation` — passed на локальном arm64 Docker host. Оба application containers
  сообщили version `0.4.3`; mock stage→activate и failpoint→retry client prepare завершились
  строкой `Interaction suite passed`. После проверки выполнен `docker compose down --volumes`.
- Локальная имитация выпуска содержит ровно семь файлов для `v0.4.3`.
  `sha256sum --check SHA256SUMS` завершился `OK` для YAML, digest-файла и четырёх `.ps1`, а
  сгенерированный YAML прошёл `docker compose config --quiet`.

- CI ветки `main` для commit `c6b0f8b` завершился успешно: Python/JavaScript, Compose interaction
  и Windows PowerShell 5.1/Pester прошли. Publish workflow для tag `v0.4.3` повторно выполнил
  тот же gate, собрал linux/amd64 image, создал provenance attestation и GitHub Release.
- Опубликованный GitHub Release `v0.4.3` скачан повторно. Он содержит ровно семь assets;
  `sha256sum --check SHA256SUMS` завершился `OK` для YAML, digest-файла и четырёх `.ps1`.
  Release YAML прошёл `docker compose config --quiet`, содержит два одинаковых image reference
  `ghcr.io/xerz/iscsi-reset-service@sha256:30f7ac8a891145bd728031b21f82f0d188ad3186e77aac013958a4b3ffc21e7e`,
  два placeholder управляющего IP-адреса и не содержит старых Admin API artifacts.

Фактическое переключение одного Windows ПК между master и client target, классификация реальных
сеансов TrueNAS и повторное разрешение stage/activation после полного отключения остаются
ожидающими физического стенда.

## Документация и комплект выпуска v0.4.2 — 2026-08-22

Эта ещё не опубликованная версия расширяет русскоязычный README и добавляет четыре
самостоятельных операторских PowerShell-файла в комплект GitHub Release. API, schema v3,
SQLite и рабочая логика сервисов не менялись. Исторические результаты v0.4.1 ниже сохраняются;
результаты новых проверок v0.4.2 добавлены отдельным списком.

### Проверки изменений v0.4.2

- `ruff check src tests` — passed.
- `pytest -q` на локальном Python 3.12 — **116 passed**.
- `node --check src/iscsi_reset_service/static/app.js`, `docker compose config --quiet` и
  `git diff --check` — passed.
- Три Mermaid-схемы из README отрендерены через `@mermaid-js/mermaid-cli` в SVG и PNG;
  синтаксис прошёл, подписи просмотрены визуально, пересекавшиеся подписи первой схемы
  упрощены.
- Локальная имитация каталога выпуска содержит ровно семь файлов: YAML, `image-digest.txt`,
  `SHA256SUMS` и четыре операторских `.ps1`. В Linux-контейнере
  `sha256sum --check SHA256SUMS` завершился `OK` для всех шести проверяемых файлов.
- Сгенерированный YAML прошёл `docker compose config --quiet` и содержит два одинаковых
  digest-pinned `image`.
- `docker compose up --build --abort-on-container-exit --exit-code-from windows-simulation` —
  passed на локальном arm64 Docker host: оба application containers сообщили version `0.4.2`,
  выполнены mock stage→activate и failpoint→retry client prepare, итог —
  `Interaction suite passed`. После прогона выполнен `docker compose down --volumes`.
- GitHub Actions для commit `66917b0` завершились успешно в двух workflow: Python, Compose и
  Windows PowerShell 5.1/Pester прошли как в `main`, так и перед публикацией tag `v0.4.2`.
- Опубликованный GitHub Release `v0.4.2` скачан повторно. Он содержит ровно семь assets;
  `sha256sum --check SHA256SUMS` завершился `OK` для YAML, digest-файла и всех четырёх `.ps1`.
  Release YAML прошёл `docker compose config --quiet`, содержит два одинаковых image reference
  `ghcr.io/xerz/iscsi-reset-service@sha256:2cfbb2807bebb91f8cb39524243d94028699a8b59ff653c4a35cbd2afc79ba7f`
  и два placeholder управляющего IP-адреса. Устаревшие Admin API artifacts отсутствуют.

### Исторические проверки v0.4.1

- `ruff check src tests` — passed.
- `pytest -q` на локальном Python 3.12 — **114 passed**.
- `node --check src/iscsi_reset_service/static/app.js` и `git diff --check` — passed.
- `docker compose config --quiet` — passed.
- `docker compose up --build --abort-on-container-exit --exit-code-from
  windows-simulation` — passed на локальном arm64 Docker host: два application containers
  сообщили version `0.4.1`, Management выполнил mock stage→activate до Publisher reconnect,
  Reset API прошёл fault→retry client prepare, suite завершился `Interaction suite passed`.
  После прогона выполнен `docker compose down --volumes`.
- Release renderer с тестовым immutable digest и последующий `docker compose -f <bundle>
  config --quiet` — passed. Bundle содержит ровно два одинаковых digest-pinned image reference,
  два management-IP API placeholder и не содержит `:8444`, admin TLS/client secrets или
  TrueNAS API URL на loopback.
- Все PowerShell tests выполнены в pinned Linux PowerShell image с Pester 6.1.0 — **19 passed**.
  Это дополнительная проверка syntax/logic, не Windows PowerShell 5.1.
- В in-app browser на локальном mock runtime пройдены management login, все шесть разделов,
  form↔YAML, одноразовый client token с очисткой raw value после dialog, config save, restart
  banner и блокировка release action до restart. Desktop и viewport `390×844` проверены
  визуально; frontend console не содержала warnings/errors.

Исторические результаты v0.3.x не считаются проверкой архитектуры v0.4.x.

### Операторские данные реального TrueNAS 25.10

Оператор подтвердил на физическом TrueNAS:

- `pool.dataset.query` должен запрашивать `properties: ["keystatus"]`; тогда master zvol и
  filesystem clone parents возвращают вычисленное `locked: false`. Значения `true` и `null`
  по-прежнему исключаются fail-closed.
- `SSDGames/MainGames`, `Sas/Games-Device/Older-Games/oldergames`,
  `SSDGames/clients/{chimera,beast}` и `Sas/clients/{chimera,beast}` были подтверждены как
  unlocked объекты ожидаемых типов.
- TrueNAS middleware не разрешил добавить `127.0.0.1` в `ui_address`, а соединение контейнера к
  `wss://127.0.0.1/api/current` отклонялось. Из контейнера нужен назначенный машине management
  IP TrueNAS; Publisher NAT/VIP для этого не используется.
- На Management UI v0.4.0 базовый discovery начал работать с обновлённым token/key, но live
  dashboard возвращал dependency 503 до выдачи discovery user роли `SNAPSHOT_READ`. После
  добавления роли live state заработал. Это подтверждает, что `SNAPSHOT_READ` входит в
  обязательный read-only набор для проверки release snapshots и `@clean`.
- Реальный `iscsi.target.query` возвращает `auth_networks` на верхнем уровне target, отдельно
  от `groups`. Ответ target `master` содержал `auth_networks: ["10.20.40.20/32"]`, тогда как
  v0.4.0 ошибочно искал это поле внутри каждого group и поэтому fail-closed сообщал ложный
  `publisher target does not authorize the exact source IP /32`. Hotfix v0.4.1 читает
  фактическую форму TrueNAS 25.10; patched image ещё требует повторной проверки на стенде.

Эти данные подтверждают discovery prerequisites, но не проверяют новый management release
workflow.

### Обязательно ожидает физического TrueNAS/Windows стенда

- Полный least-privilege набор read-only discovery key и отдельного mutation service key на
  фактическом patch release TrueNAS SCALE 25.10; необходимость `SNAPSHOT_READ` для discovery
  user уже подтверждена оператором.
- Два production containers, реальные directory mounts, POSIX lock/history/fsync и доступ к
  Management UI только через SSH tunnel.
- Реальная классификация Publisher/client iSCSI sessions, включая partial identity conflict.
- Dual-role Windows ПК: взаимоисключающее подключение master/client target, понятные role
  warnings и fail-closed блокировка prepare/stage/activation до полного отключения другой роли.
- Dashboard mapping по extent path, managed ZFS properties, origin snapshot и `@clean`.
- Publisher helper `Disconnect`/`Reconnect` на Windows PowerShell 5.1: exact NAA, offline,
  pending recovery, непостоянная session и безопасный online.
- Stage/activation при отключённом Publisher, activation до reconnect, отказ при неожиданном
  reconnect и reconciliation incomplete release с исходным request ID.
- Корректность snapshot existence, clone dependencies и строгого отчёта «кандидат для ручной
  очистки» на реальном storage. Автоматическое удаление не реализовано и не разрешено.
- Реальный Reset API TLS, Windows client prepare/reset, NTFS и сохранность NAA/serial/LUN.

До выполнения этих пунктов нельзя объявлять физический TrueNAS/Windows flow пройденным. Порядок
и ограничения destructive-проверок приведены в `TEST-PLAN.md`.
