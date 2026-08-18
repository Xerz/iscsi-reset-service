# Verification record — v0.2.0

Дата локальной проверки: 2026-08-18.

## Пройдено

- `ruff check .` — passed.
- `pytest -q` на Python 3.14.4 — **76 passed**.
- PowerShell parser — все `.ps1` разобраны без syntax errors.
- Pester 5.7.1 в закреплённом PowerShell-контейнере — **23 passed**.
- `docker compose config --quiet` — passed.
- Container build Python 3.12 — passed.
- Compose interaction suite — passed.
- Renderer release bundle с тестовым `sha256` digest и последующий
  `docker compose -f <bundle> config --quiet` — passed.
- GitHub Actions CI run `32135742007`: Python/Ruff, Windows PowerShell 5.1 Pester и Compose
  interaction jobs — passed.
- Release gate run `32136015989`: tag/version validation, Python/Ruff, Windows PowerShell 5.1
  Pester и Compose interaction jobs — passed.
- Образ `ghcr.io/xerz/iscsi-reset-service:v0.2.0` опубликован с SBOM и provenance;
  release bundle создан с digest
  `sha256:15808835c03e129241c69d32ed264e58fc7309e9b5d164450ed511bef2b3b7c8`.
- Скачанный workflow artifact: `SHA256SUMS` — passed, обе службы используют один digest,
  `docker compose config --quiet` — passed; из этих файлов создан GitHub Release `v0.2.0`.
- Анонимный GHCR pull-token и manifest request — HTTP 200, manifest digest совпал с release
  bundle; пользовательские registry credentials не использовались.

Pytest покрывает:

- schema v2, master/client volume mapping и запрет конфликтующих identity/extent/LUN;
- release bundle: lowercase GHCR repository, точные две digest-ссылки, сохранение локальных
  placeholders и отказ на неверном digest/числе image placeholders;
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

- Установка публичного digest-pinned GHCR image в настоящий TrueNAS SCALE 25.10 Custom App.
- Реальный mTLS handshake на management NIC TrueNAS; unit/deployment проверки подтверждают
  обязательный `ssl.CERT_REQUIRED`, но сертификаты конкретной сети ещё не выпущены.
- Подбор минимальных ролей TrueNAS API-пользователя на конкретной patch release.
- Реальное соответствие extent NAA полю Windows `Get-Disk.UniqueId`.
- Offline/disconnect/reconnect физических master LUN.
- Destructive rollback тестового 1 GiB zvol и параллельная загрузка Chimera/Beast.
- Поведение SQLite bind mount и POSIX locks после реального TrueNAS App redeploy.

До прохождения `TEST-PLAN.md` программная часть считается проверенной, а deployment и
физические storage-сценарии — ожидающими стенда.

## Инцидент первого release run

Первый `v0.2.0` run успешно опубликовал image, attestation и workflow artifact, но финальный
shell step создания GitHub Release завершился syntax error из-за пропущенного `fi`. Release
создан из checksum-проверенного artifact без повторной публикации image; `fi` добавлен в `main`
и shell block проверен через `bash -n`. Полный corrected tag run будет подтверждён следующим
version tag; результат первого run не переименован в success.
