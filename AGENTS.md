# AGENTS.md — правила работы с iSCSI Reset Service

Эти инструкции действуют для всего дерева `outputs/iscsi-reset-service/`.

Проект управляет writable iSCSI LUN и ZFS snapshots. Ошибка здесь может повредить данные или
подключить Windows промежуточный набор дисков. Любое изменение должно сохранять fail-closed
поведение: при сомнении extents остаются выключенными, а клиент не получает `ready`.

## С чего начинать

Перед изменениями прочитайте:

1. `README.md` — архитектура, установка и публичные контракты;
2. `VERIFICATION.md` — что действительно проверено, а что ещё ожидает стенда;
3. `TEST-PLAN.md` — физические и destructive-проверки;
4. `MIGRATION-v1-v2.md` — граница поддержки конфигурации;
5. затрагиваемые модули и соответствующие тесты.

Не считайте mock/Compose доказательством работы с реальными TrueNAS, NTFS, сертификатами или
Windows PowerShell 5.1. Эти границы всегда отражайте в `VERIFICATION.md`.

## Источники истины

- `config/config.example.yaml` — документированный пример статической schema v2.
- `src/iscsi_reset_service/config.py` — фактическая схема и все topology-инварианты.
- `src/iscsi_reset_service/release_store.py` — схема SQLite и транзакционные правила.
- `src/iscsi_reset_service/release_manager.py` — state machine публикации master release.
- `src/iscsi_reset_service/coordinator.py` — state machine клиентского prepare/reset.
- `src/iscsi_reset_service/backends/base.py` — абстрактный storage-контракт.
- `src/iscsi_reset_service/backends/truenas.py` — TrueNAS 25.10 JSON-RPC mapping.
- `src/iscsi_reset_service/backends/mock.py` — тестовая модель наблюдаемого состояния.
- `src/iscsi_reset_service/api.py` — reset API; его Windows-контракт стабилен.
- `src/iscsi_reset_service/admin_api.py` — management/admin API.
- `truenas/custom-app.yaml` — production-like deployment topology.
- `compose.yaml` и `tests/interaction/` — локальный сквозной mock-стенд.

README и примеры должны меняться в том же наборе изменений, что и кодовый контракт.

## Архитектурные границы

### Статическая конфигурация

- Поддерживается только `schema_version: 2`.
- YAML описывает topology, identities, extents, LUN и volume mapping.
- В YAML не должны возвращаться `releases`, `active_release` или `release_override`.
- Ключи `publisher.volumes` произвольны. Никогда не хардкодьте `ssd`, `hdd` или количество
  дисков в Python, API, PowerShell либо тестовых helper-функциях.
- Клиент может использовать подмножество publisher volumes.
- Pool master dataset и соответствующего client clone обязан совпадать.
- IP, IQN, target, token digest и extent ID должны быть глобально уникальны; LUN и буквы
  проверяются в предусмотренной схемой области.

### Динамическое состояние

- Releases, `volume → snapshot`, `incomplete/staged`, idempotency, audit и active pointer
  хранятся только в SQLite.
- Production path по умолчанию: `/state/releases.sqlite3`.
- Reset role открывает SQLite read-only; admin/CLI — read-write.
- Release mapping после `staged` immutable.
- Activation меняет только active pointer одной SQLite-транзакцией.
- Не удаляйте автоматически старые releases, snapshots или clones.
- Не выбирайте active release по времени, имени или «самому новому» snapshot.
- Изменение DB schema требует увеличения SQLite `user_version`, явной миграции или намеренного
  отказа с понятной ошибкой и тестами restart persistence.

### Сетевые роли

- iSCSI portal: `10.20.40.10:3260`.
- Reset API: SAN IP `10.20.40.10:8443`, client Bearer token + точный SAN source IP.
- Admin API: только выделенный management IP `:8444`, одновременно mTLS + отдельный admin
  Bearer token + точный management IP Threadripper.
- Не доверяйте `X-Forwarded-For`: сервер запускается с `proxy_headers=False`.
- `ALLOW_TEST_SOURCE_HEADER` допустим только с mock backend и никогда с TrueNAS backend.
- Отключение TLS-проверки App → TrueNAS допустимо только при точном подтверждении
  `TRUENAS_TLS_INSECURE_ACK=I_ACCEPT_MITM_RISK`.

## Обязательные safety-инварианты

### Client prepare/reset

1. Идентифицировать клиента по token и проверить source IP.
2. Проверить отсутствие session по source IP, initiator IQN и target IQN.
3. Выключить все extents клиента; сбой оставляет весь набор выключенным.
4. Повторно проверить отсутствие session.
5. Читать active release только из SQLite и требовать полный mapping нужных volumes.
6. Проверить origin, user properties и `@clean` каждого clone.
7. При миграции сохранять extent ID, serial и NAA.
8. Rollback выполнять без recursive/destructive/force флагов.
9. Включать LUN только после полной сверки paths, NAA, LUN и enabled state.
10. Возвращать `ready` только после проверки всего набора.

Reset API не сообщает release name, snapshot paths или чужой target. Его успешный ответ содержит
только portal, собственный target и `{lun, disk_unique_id, drive_letter, label}`.

### Release stage/activate

1. Проверить mTLS на уровне сервера, admin token и source IP.
2. Сверить полный publisher target: extent ID, dataset path, LUN, NAA и serial.
3. До любых mutations потребовать отсутствие publisher session по SAN IP, initiator IQN и
   target IQN.
4. Выключить все master extents и повторно проверить session.
5. Зарезервировать release и `X-Request-ID` в SQLite до первого snapshot.
6. Создавать snapshots с `recursive=false` и `vmware_sync=false`.
7. После каждого snapshot фиксировать прогресс в SQLite.
8. При retry принимать существующий snapshot только если он принадлежит зарезервированному
   release и ожидаемому volume.
9. Включать master extents только после полной сверки согласованного набора.
10. Переводить release в `staged` только после финальной проверки.

Частичная ошибка не меняет active release, не удаляет snapshots и оставляет master extents
выключенными. Другой request ID не может обойти `incomplete`; исходный request ID продолжает
reconciliation. Activation требует точную строку `ACTIVATE <release>`.

### Windows PowerShell

- Скрипты должны оставаться совместимыми с Windows PowerShell 5.1.
- До любой disk mutation сопоставьте полный набор дисков по точному target/session и NAA.
- Допустимая нормализация UniqueId: whitespace, регистр и необязательный префикс `0x`.
- Не сопоставляйте диски по номеру, размеру, label, порядку enumeration или drive letter.
- Не используйте `Initialize-Disk`, `Format-Volume`, `Clear-Disk`, `New-Partition`, удаление
  partition либо другие provisioning-команды.
- Client login всегда `IsPersistent=false`.
- Если ошибка произошла после нового login, отключите только созданную этим запуском session.
- Publisher при ошибке `stage` не переподключает master target.
- Секреты не должны попадать в JSONL, exceptions, stdout или audit.
- На конкретной машине различаются только защищённые token/certificate/config файлы под
  `C:\ProgramData`; сами `.ps1` общие.

## Правила реализации

- Python: 3.12+, type hints, line length 100, правила Ruff из `pyproject.toml`.
- Не принимайте dataset, snapshot, extent ID, target или release name от игрового клиента.
- Всегда reconcile по фактически прочитанному состоянию backend; не предполагайте, что
  предыдущий mutation завершился.
- Все группы mutations должны быть повторяемыми с тем же request ID.
- Locks защищают клиента либо глобальную release operation, но не заменяют проверки storage
  state.
- Ошибки безопасности и неполное состояние должны быть типизированы существующими кодами
  `401/403/409/423/503`, не превращаться в optimistic success.
- Не ослабляйте container hardening: UID/GID `10001`, read-only root, `cap_drop: ALL`,
  `no-new-privileges`, без privileged, Docker socket и `/dev/zvol`.
- Production image всегда закрепляется digest, а не только tag.
- Не добавляйте автоматическое удаление storage objects без отдельного утверждённого дизайна и
  физических recovery-тестов.

## TrueNAS backend

- Целевая версия API: TrueNAS SCALE 25.10, `wss://127.0.0.1/api/current`.
- Используйте официальные JSON-RPC методы и точные payloads.
- При добавлении backend operation сначала расширьте `StorageBackend`, затем TrueNAS и Mock
  реализации, после чего добавьте payload unit test.
- Mock обязан моделировать важное наблюдаемое состояние и partial failures, а не просто
  возвращать success.
- Нельзя выполнять storage-команды на реальном TrueNAS из автоматических локальных тестов.

## Проверки

Минимум для Python/config/API изменения:

```bash
python -m pip install -e '.[test]'
ruff check src tests
pytest -q
```

Для deployment, SQLite interaction, backend state machine или API integration дополнительно:

```bash
docker compose config --quiet
docker compose up --build --abort-on-container-exit --exit-code-from windows-simulation
docker compose down --volumes
```

Для PowerShell изменения на Windows PowerShell 5.1:

```powershell
Invoke-Pester .\powershell\tests -Output Detailed -CI
```

Если Windows runner недоступен, допускается дополнительный PowerShell container run, но в
`VERIFICATION.md` явно укажите, что это не Windows PowerShell 5.1.

Новые mutation phase или ветка partial failure требуют теста успешного пути, падения сразу
после mutation и retry/reconciliation. Изменение количества volumes должно проверяться набором,
отличным от двух дисков.

## Изменения контрактов

При изменении schema/API/SQLite/PowerShell одновременно проверьте и при необходимости обновите:

- Pydantic models и validation;
- `config/config.example.yaml`;
- unit, API, state-machine и interaction tests;
- `README.md` и `MIGRATION-v1-v2.md`;
- `truenas/custom-app.yaml`, Docker/Compose environment;
- PowerShell installers и scripts;
- `TEST-PLAN.md` и `VERIFICATION.md`.

Reset API контракт с существующим Windows-клиентом сохраняйте обратно совместимым. Если это
невозможно, изменение требует отдельной версии API и явного плана обновления клиентов.

## Документирование результата

- В `VERIFICATION.md` записывайте только фактически выполненные команды и окружение.
- Не меняйте «ожидает стенда» на «пройдено» на основании unit/mock/Compose.
- Физические destructive tests выполняются только по `TEST-PLAN.md` на выделенном тестовом zvol
  после подтверждения точных targets/datasets.
- При изменении архитектуры обновляйте страницу Notion
  [«Сетевой вариант дисков с играми»](https://app.notion.com/p/3bdc2ece9496803f9ee0c73538832678),
  если в текущей сессии доступен Notion и пользователь разрешил изменение внешнего состояния.
- Не вставляйте в документацию реальные raw tokens, peppers, API keys, PFX passwords или
  приватные ключи.

## Перед завершением задачи

- Просмотрите diff и убедитесь, что unrelated пользовательские изменения сохранены.
- Проверьте отсутствие generated artifacts (`__pycache__`, `.pytest_cache`, local SQLite,
  certificates, tokens) в комплекте. Детерминированные dummy fixtures
  `tests/interaction/token-pepper` и `tests/interaction/admin-token-pepper` являются частью
  mock-suite и не считаются реальными секретами.
- Выполните релевантный минимальный и сквозной набор тестов.
- Обновите `VERIFICATION.md` без завышения уровня проверки.
- В итоговом сообщении разделите: реализовано, автоматически проверено, ожидает реального
  TrueNAS/Windows стенда.
