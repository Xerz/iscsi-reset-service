# Verification record

## Hotfix worktree v0.3.1 — 2026-08-20

### Операторские доказательства исходной ошибки на TrueNAS 25.10

Ниже записаны результаты, которые оператор получил на физическом TrueNAS до сборки patched
image. Это доказательство причины дефекта, но не проверка hotfix image:

- `pool.dataset.query` с прежним `properties: []` возвращал `locked: null` для master zvol и
  filesystem clone parents. Из-за fail-closed проверки configurator отклонял master как не
  подтверждённый unlocked zvol и не заполнял список Clone parent.
- Тот же query с `properties: ["keystatus"]` вернул `locked: false` и
  `keystatus.value: "NONE"` для `SSDGames/MainGames`,
  `Sas/Games-Device/Older-Games/oldergames`, `SSDGames/clients/{chimera,beast}` и
  `Sas/clients/{chimera,beast}`. Отдельные `zfs list` и `iscsi.extent.query` подтвердили тип
  `volume`, DISK extents, zvol paths и `locked: false` у extent IDs 3/4.
- TrueNAS middleware отклонил добавление `127.0.0.1` в `ui_address` как адрес, не назначенный
  машине; соединение контейнера к `wss://127.0.0.1/api/current` получало connection refused.
  Локальный management IP `192.168.3.218` является правильным адресом API для этого стенда;
  Publisher NAT/VIP для него не используется.

### Автоматически и локально пройдено

- `ruff check src tests` — passed.
- `pytest -q` на Python 3.14.4 — **103 passed**. Предупреждения относятся к deprecated asyncio
  policy API тестового окружения Python 3.14.
- `node --check src/iscsi_reset_service/static/app.js` — passed.
- `docker compose config --quiet` — passed.
- `docker compose up --build --abort-on-container-exit --exit-code-from
  windows-simulation` — passed на локальном arm64 Docker host; `Interaction suite passed`, все
  три контейнера сообщили version `0.3.1`. После прогона выполнен
  `docker compose down --volumes`.
- Release renderer с тестовым digest и последующий `docker compose config --quiet` — passed:
  три одинаковые digest-pinned image references, три management-IP `TRUENAS_API_URL`, ни одного
  TrueNAS API URL на loopback.
- В in-app browser на локальном mock backend пройден regression-сценарий: неверный token
  оставляет login error; правильный token и первый discovery `503` открывают authenticated
  shell с `Discovery unavailable`, неизвестными counts и отключёнными validate/apply/save;
  успешный refresh возвращает badge `TrueNAS discovery OK`, включает действия, показывает три
  targets, шесть datasets и clone parents из обоих pools.

### Ожидает patched image и физических стендов

- Patched image v0.3.1 ещё должен быть установлен на реальный TrueNAS 25.10. До этой проверки
  реальный configurator flow не считается пройденным.
- После установки заново проверить `locked: false` для двух master zvol и наличие
  `SSDGames/clients/{chimera,beast}` и `Sas/clients/{chimera,beast}` в соответствующих списках
  Clone parent, затем выполнить save/restart/revision flow.
- Реальные Windows PowerShell 5.1/Pester, publish workflow, checksum и release-bundle проверки
  будут зафиксированы после CI/tag; локальный Compose PowerShell simulation не заменяет
  Windows runner.

## Configurator worktree v0.3.0 — 2026-08-19

### Автоматически и локально пройдено

- `ruff check src tests` — passed.
- `pytest -q` на Python 3.14 — **100 passed**. Предупреждения относятся к deprecated asyncio
  policy API в тестовом окружении Python 3.14, падений нет.
- `node --check src/iscsi_reset_service/static/app.js` — passed.
- `docker compose config --quiet` — passed.
- `docker compose up --build --abort-on-container-exit --exit-code-from
  windows-simulation` — passed на локальном arm64 Docker host; контейнер приложения собран с
  Python 3.12, закреплённый PowerShell simulation image запущен через amd64 emulation.
- Compose interaction подтвердил третий loopback-only configurator, login/CSRF, live
  validation, запись нового revision в directory mount, отсутствие hot reload, а затем прежние
  stage/activate и fault → retry reset сценарии. После прогона выполнен
  `docker compose down --volumes`.
- Renderer `python -m iscsi_reset_service.release_bundle` с тестовым digest и затем
  `docker compose -f <rendered-bundle> config --quiet` — passed; bundle содержит ровно три
  одинаковые digest-pinned image references.
- `git diff --check` — passed.

Unit/API tests дополнительно покрывают discovery-модели и точные TrueNAS JSON-RPC query
payloads, canonical YAML и duplicate keys, IQN normalization, locked/file extent и dataset
фильтры, session/Host/Origin/CSRF/expiry/request-size проверки, одноразовые token digests,
optimistic revision conflict, active/incomplete release guards, отсутствующую/повреждённую
SQLite и сбои atomic replace с сохранением предыдущего файла/history.

### Browser E2E на локальном mock backend

Через `@playwright/cli` фактически пройдены два сценария:

1. Редактирование существующего config: восстановление session после reload, form → YAML и
   YAML → form, token generation, очистка raw token и отсутствие local/session storage,
   duplicate-key validation, atomic save, history mode `0600` и restart banner.
2. Первичная установка без `config.yaml` и SQLite: выбор publisher/client topology из
   discovery, live validation, создание canonical `config.yaml` mode `0600`, различающиеся
   `startup: нет`/saved revision и обязательный restart banner.

Browser и временный mock server остановлены; тестовые raw tokens и browser artifacts не входят
в repository.

### Простой редизайн конфигуратора — 2026-08-19

- В in-app browser на локальном mock backend проверены login и все пять разделов: простые
  status-показатели, двухколоночная форма сети, таблица publisher volumes, последовательные
  client cards с таблицами volumes и отдельный YAML editor.
- Повторно пройдены form → YAML и YAML → form, генерация client token с одноразовым
  dialog, duplicate-key validation, сохранение config и restart banner.
- Визуально проверены обычный desktop viewport и mobile `390×844`: навигация остаётся
  доступной, таблицы переходят в подписанные формы, нижняя save panel не перекрывает поля.
- После UI-изменений повторно пройдены `ruff check src tests`, `pytest -q` (**100 passed**),
  `node --check src/iscsi_reset_service/static/app.js`, `git diff --check`,
  `docker compose config --quiet` и полный Compose interaction. После прогона выполнен
  `docker compose down --volumes`.
- Frontend API, schema v2, draft model и storage safety-логика не изменялись; новые frontend
  dependencies, framework, внешние assets и шрифты не добавлялись.

### Опубликованный release v0.3.0 — 2026-08-19

- Commit `b18ab7131c896f53be62228c464075a65772f257` опубликован в `main` и помечен
  аннотированным tag `v0.3.0`.
- GitHub CI run `32272982346` — passed: Python/Ruff, Windows PowerShell 5.1 Pester и Compose
  interaction.
- Release run `32273248337` — passed: tag/version validation, тот же полный verification gate,
  публикация GHCR image, SBOM/provenance attestation, renderer bundle и GitHub Release.
- Опубликованный immutable image digest:
  `sha256:7819da963b44e5673c0d9a446c5edbc7cdf47b0c6976ecd251178c20ae5329c7`.
- С GitHub Release заново скачаны `iscsi-reset-service-v0.3.0-truenas.yaml`,
  `image-digest.txt` и `SHA256SUMS`; `sha256sum --check SHA256SUMS` — passed,
  `docker compose -f iscsi-reset-service-v0.3.0-truenas.yaml config --quiet` — passed, все три
  service image references совпадают с опубликованным digest.
- Анонимное получение GHCR pull token и manifest по tag и immutable digest — HTTP 200;
  `docker-content-digest` точно совпал с release bundle.

### Bootstrap-документация после v0.3.0 — 2026-08-19

- README дополнен последовательной подготовкой до установки App: master/bootstrap zvol и clone
  parents, iSCSI objects, служебные datasets, UID/GID и modes, API credentials, peppers,
  configurator token, TLS files, GUI/manual bootstrap и first-restart checks.
- Runtime/discovery role lists сверены с официальными role requirements TrueNAS API v25.10.5;
  для `pool.snapshot.rollback` используется более узкая альтернативная роль `SNAPSHOT_WRITE`,
  поэтому `POOL_WRITE` не добавлен.
- `git diff --check` — passed. Код, schema, deployment YAML и release artifacts не изменялись.
- Команды и минимальные privileges остаются ожидающими выполнения на физическом TrueNAS по
  `TEST-PLAN.md`; документальная сверка не считается стендовой проверкой.

### Уточнение bootstrap-документации — 2026-08-20

- В README разделены initiator IQN и target `Authorized Networks`: IQN задаётся в initiator
  group, SAN source IP `/32` — в target, что соответствует TrueNAS 25.10 UI/API model.
- Для Admin API разделены `ADMIN_BIND_IP`, клиентский `ADMIN_CONNECT_IP`/certificate SAN и
  фактически наблюдаемый после NAT source IP; NAT-сценарий не считается проверенным на стенде.
- GUI bootstrap расписан до уровня действий в TrueNAS/SSH/browser: loopback tunnel, пять
  разделов, одноразовые raw tokens, live validation, save и полный app restart; отдельно
  задокументирован отказ `administratively prohibited` при выключенном TCP port forwarding.
- Добавлена пошаговая private PKI для новичка: три независимых CA, два server certificates с
  SAN/serverAuth, Publisher client certificate с clientAuth, password-protected PFX, матрица
  распространения и TrueNAS file permissions.
- Полная последовательность OpenSSL-команд выполнена локально с dummy IP/keys на OpenSSL 3.6.2:
  три `openssl verify` с `sslserver`/`sslclient`, обе `x509 -checkip` и чтение PFX — passed.
- Реальный импорт PFX в Windows PowerShell 5.1, TLS/mTLS handshake, SAN IP конкретного TrueNAS и
  certificate rotation остаются ожидающими физического стенда.

### Ожидает отдельной среды

- Минимальный набор read-only ролей discovery user на реальном TrueNAS SCALE 25.10 patch
  release.
- Реальный SSH tunnel к TrueNAS и подтверждение, что configurator недоступен иначе.
- Реальный Custom App directory mount, POSIX lock/history/fsync и restart/revision flow после
  redeploy.
- Реальные iSCSI/NTFS/NAA, mTLS и destructive ZFS проверки из `TEST-PLAN.md`.

Mock/unit/Compose/browser результаты не считаются доказательством физического TrueNAS/Windows
поведения.

## Историческая проверка v0.2.0

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
