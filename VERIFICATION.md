# Verification record

## Management UI hotfix worktree v0.4.1 — 2026-08-22

Этот worktree заменяет отдельные Configurator и Admin API одной loopback-only Management UI,
переводит статическую конфигурацию на schema v3 и заменяет сетевой Publisher workflow локальным
manifest-driven PowerShell helper. Основные изменения опубликованы в release `v0.4.0`; записи
ниже дополнены операторскими результатами и пока не опубликованным hotfix `v0.4.1`.

### Автоматически и локально пройдено

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
