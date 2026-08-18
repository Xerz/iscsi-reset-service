# Verification record — v0.2.0

Дата локальной проверки: 2026-08-18.

## Пройдено

- `ruff check src tests` — passed.
- `pytest -q` — **70 passed**.
- PowerShell parser — все `.ps1` разобраны без syntax errors.
- Pester 5.7.1 в закреплённом PowerShell-контейнере — **23 passed**.
- `docker compose config --quiet` — passed.
- Container build Python 3.12 — passed.
- Compose interaction suite — passed.

Pytest покрывает:

- schema v2, master/client volume mapping и запрет конфликтующих identity/extent/LUN;
- SQLite initialization, read-only mode, persistence, immutable snapshots и atomic activation;
- admin token/IP, API contracts и скрытие release data от игрового клиента;
- stage, activation, active publisher session и release lock;
- fail-closed восстановление после каждой mutation phase, включая второй snapshot и повторное
  включение master extents;
- ленивую клиентскую миграцию, rollback, NAA/serial и изоляцию Chimera/Beast;
- точные TrueNAS `pool.snapshot.create` и `iscsi.extent.update` payloads.

Pester покрывает:

- reset retry с тем же request ID;
- exact target/NAA/disk/letter mapping и disconnect при ошибке;
- publisher exact NAA preflight до offline/disconnect;
- stage → reconnect → activate/decline flow, восстановление staged pending release,
  остановку activation при reconnect failure и отсутствие reconnect после stage failure;
- отсутствие `Initialize-Disk`, `Format-Volume`, `Clear-Disk`, `New-Partition`.

Compose запускает два API с общей SQLite и общий persistent mock TrueNAS. Сценарий выполняет:

1. admin stage;
2. atomic activate;
3. reset prepare с инъекцией первого `503`;
4. retry/reconciliation с тем же request ID;
5. подключение simulated Windows LUN;
6. wrong-NAA отказ с disconnect и сохранением локального системного диска.

## Намеренно не заявлено как пройденное

- Установка private GHCR image в настоящий TrueNAS SCALE 25.10 Custom App.
- Реальный mTLS handshake на management NIC TrueNAS; unit/deployment проверки подтверждают
  обязательный `ssl.CERT_REQUIRED`, но сертификаты конкретной сети ещё не выпущены.
- Подбор минимальных ролей TrueNAS API-пользователя на конкретной patch release.
- Pester на настоящем Windows PowerShell 5.1 runner; локально использован PowerShell 7.5,
  а CI содержит обязательный Windows PowerShell 5.1 job.
- Реальное соответствие extent NAA полю Windows `Get-Disk.UniqueId`.
- Offline/disconnect/reconnect физических master LUN.
- Destructive rollback тестового 1 GiB zvol и параллельная загрузка Chimera/Beast.
- Поведение SQLite bind mount и POSIX locks после реального TrueNAS App redeploy.

До прохождения `TEST-PLAN.md` программная часть считается проверенной, а deployment и
физические storage-сценарии — ожидающими стенда.
