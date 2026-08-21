# iSCSI Reset Service v0.4.0

Сервис публикует согласованные ZFS snapshots master iSCSI LUN и перед каждым подключением
игрового ПК переключает его постоянные extents на writable clones активного release. Все
опасные операции выполняются fail-closed: при сомнении extents остаются выключенными, а клиент
не получает `ready`.

## Архитектура

В TrueNAS Custom App работают два контейнера из одного digest-pinned image:

- `iscsi-reset-api` — HTTPS Reset API на SAN IP `:8443`, config и SQLite read-only;
- `iscsi-reset-management` — Administration UI на `127.0.0.1:8445`, config и SQLite read-write.

Панель открывается только через SSH-туннель. Отдельного Admin API, порта `8444`, mTLS и
Publisher API credentials нет. Publisher использует локальный PowerShell helper, который
проверяет NAA и отключает/подключает master target, но не обращается к сервису по сети.

Статическая topology хранится в `config.yaml` schema v3. Releases, immutable
`volume → snapshot` mappings, incomplete state, active pointer и audit находятся только в
`/state/releases.sqlite3`.

## Подготовка TrueNAS до установки App

### 1. Служебные datasets

Создайте parent `tank/iscsi-reset`, затем четыре дочерних **Filesystem** datasets без SMB/NFS
shares:

```text
tank/iscsi-reset/config   → /mnt/tank/iscsi-reset/config
tank/iscsi-reset/state    → /mnt/tank/iscsi-reset/state
tank/iscsi-reset/secrets  → /mnt/tank/iscsi-reset/secrets
tank/iscsi-reset/tls      → /mnt/tank/iscsi-reset/tls
```

TrueNAS автоматически монтирует обычный dataset под `/mnt/<pool>/<dataset>`. В форме
**Datasets → Add Dataset** достаточно выбрать `tank/iscsi-reset` как parent, задать имя и тип
`Generic`; отдельный mountpoint вручную не нужен.

Подготовьте права:

```bash
sudo chown -R 10001:10001 /mnt/tank/iscsi-reset/config \
  /mnt/tank/iscsi-reset/state \
  /mnt/tank/iscsi-reset/secrets \
  /mnt/tank/iscsi-reset/tls
sudo chmod 0700 /mnt/tank/iscsi-reset/config \
  /mnt/tank/iscsi-reset/state \
  /mnt/tank/iscsi-reset/secrets \
  /mnt/tank/iscsi-reset/tls
```

Не создавайте пустой `config.yaml`: Management UI умеет выполнить первоначальную настройку
при полном отсутствии файла.

### 2. Master и client datasets

Для каждого логического volume создайте master zvol. Для каждого клиента и pool создайте
отдельный Filesystem clone parent. Например:

```text
SSDGames/MainGames                         master zvol
Sas/Games-Device/Older-Games/oldergames    master zvol
SSDGames/clients/chimera                   clone parent filesystem
Sas/clients/chimera                        clone parent filesystem
```

Pool master zvol и соответствующего clone parent обязан совпадать. File extents, locked zvol и
clone parents другого pool не поддерживаются.

### 3. iSCSI topology

1. Создайте portal на выделенном SAN IP, например `10.20.40.10:3260`.
2. Для Publisher создайте отдельные initiator group и target. В initiator group указывается
   точный IQN. SAN IP Publisher с `/32` задаётся в **Authorized Networks** target group.
3. Для каждого master zvol создайте Device/DISK extent и target–extent association с
   фиксированным LUN.
4. Для каждого игрового ПК создайте отдельные initiator group и target. IQN задаётся в
   initiator group, IP `/32` — в **Authorized Networks** target group.
5. Для каждого client volume создайте постоянный Device/DISK extent, первоначально направленный
   на отдельный bootstrap zvol, и association. После проверки выключите client extent.

Никогда не переиспользуйте extent record между targets. Service меняет у client extent только
`disk` и `enabled`; ID, NAA и serial должны оставаться постоянными.

### 4. TrueNAS API credentials

Создайте две непривилегированные local groups/users без sudo, SSH и web shell:

| Credential | Рекомендуемый пользователь | Roles |
|---|---|---|
| Runtime mutations | `iscsi-reset-service` | `DATASET_READ`, `DATASET_WRITE`, `SNAPSHOT_READ`, `SNAPSHOT_WRITE`, `SHARING_ISCSI_GLOBAL_READ`, `SHARING_ISCSI_EXTENT_READ`, `SHARING_ISCSI_EXTENT_WRITE`, `SHARING_ISCSI_TARGET_READ`, `SHARING_ISCSI_TARGETEXTENT_READ` |
| Management discovery | `iscsi-reset-discovery` | `DATASET_READ`, `SHARING_ISCSI_GLOBAL_READ`, `SHARING_ISCSI_PORTAL_READ`, `SHARING_ISCSI_TARGET_READ`, `SHARING_ISCSI_EXTENT_READ`, `SHARING_ISCSI_TARGETEXTENT_READ`, `SHARING_ISCSI_INITIATOR_READ` |

Runtime key используется Reset API и mutation-частью панели; discovery key — только формами и
dashboard. Сохраните значения keys в:

```text
/mnt/tank/iscsi-reset/secrets/truenas_api_key
/mnt/tank/iscsi-reset/secrets/truenas_discovery_api_key
```

Не передавайте key аргументом shell-команды. Запишите его через `sudo vi` или stdin, затем:

```bash
sudo chown 10001:10001 /mnt/tank/iscsi-reset/secrets/truenas_api_key \
  /mnt/tank/iscsi-reset/secrets/truenas_discovery_api_key
sudo chmod 0400 /mnt/tank/iscsi-reset/secrets/truenas_api_key \
  /mnt/tank/iscsi-reset/secrets/truenas_discovery_api_key
```

### 5. Peppers и management token

```bash
umask 077
openssl rand -hex 32 > /mnt/tank/iscsi-reset/secrets/token_pepper
openssl rand -hex 32 > /mnt/tank/iscsi-reset/secrets/management_token_pepper
sudo chown 10001:10001 /mnt/tank/iscsi-reset/secrets/*
sudo chmod 0400 /mnt/tank/iscsi-reset/secrets/*
```

Сгенерируйте management token контейнером опубликованного image:

```bash
docker run --rm --network none --read-only --user 10001:10001 \
  --cap-drop ALL --security-opt no-new-privileges \
  -v /mnt/tank/iscsi-reset/secrets/management_token_pepper:/run/secrets/management_token_pepper:ro \
  IMAGE_AT_IMMUTABLE_DIGEST \
  management-token generate --pepper-file /run/secrets/management_token_pepper
```

Сохраните однажды показанный raw token только в password manager. В файл
`secrets/management_token_digest` поместите только строку `hmac-sha256:...`, затем задайте
`10001:10001` и `0400`. Raw token не должен попадать в YAML, history, логи или audit.

### 6. TLS Reset API

App нужны только два TLS-файла:

```text
/mnt/tank/iscsi-reset/tls/reset-server.crt
/mnt/tank/iscsi-reset/tls/reset-server.key
```

Certificate обязан иметь SAN с IP Reset API, например `IP:10.20.40.10`. Если своей PKI нет,
на доверенном компьютере с OpenSSL 3.x можно создать отдельный CA и leaf certificate:

```bash
umask 077
mkdir iscsi-reset-pki && cd iscsi-reset-pki

openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 \
  -aes-256-cbc -out reset-ca.key
openssl req -x509 -new -sha256 -days 3650 -key reset-ca.key \
  -out reset-ca.crt -subj "/CN=iSCSI Reset CA" \
  -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
  -addext "keyUsage=critical,keyCertSign,cRLSign"

openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 \
  -out reset-server.key
openssl req -new -sha256 -key reset-server.key -out reset-server.csr \
  -subj "/CN=iscsi-reset" \
  -addext "subjectAltName=IP:10.20.40.10"
printf '%s\n' \
  'basicConstraints=critical,CA:FALSE' \
  'keyUsage=critical,digitalSignature,keyEncipherment' \
  'extendedKeyUsage=serverAuth' \
  'subjectAltName=IP:10.20.40.10' > reset-server.ext
openssl x509 -req -sha256 -days 825 -in reset-server.csr \
  -CA reset-ca.crt -CAkey reset-ca.key -CAcreateserial \
  -extfile reset-server.ext -out reset-server.crt
```

Скопируйте server certificate/key на TrueNAS, а `reset-ca.crt` — на игровые ПК. CA private key
на TrueNAS или Windows не копируйте.

```bash
sudo chown 10001:10001 /mnt/tank/iscsi-reset/tls/*
sudo chmod 0400 /mnt/tank/iscsi-reset/tls/*
```

## Установка и первоначальная конфигурация

1. Возьмите `truenas/custom-app.yaml` либо release bundle.
2. Замените immutable image placeholder, все `/mnt/tank/...` paths и
   `REPLACE_WITH_TRUENAS_MANAGEMENT_IP`. Это локальный management IP TrueNAS, например
   `192.168.3.218`, а не NAT/VIP Publisher.
3. Проверьте `docker compose -f <bundle> config --quiet`.
4. Установите YAML через **Apps → Discover Apps → Custom App**.

Management server внутри контейнера слушает `127.0.0.1:8445`, поэтому обычный `curl` на вашем
компьютере без туннеля не сработает. В настройках SSH TrueNAS включите **Allow TCP Port
Forwarding**, затем на рабочем компьютере:

```bash
ssh -N -L 8445:127.0.0.1:8445 <user>@<truenas-management-ip>
```

Откройте `http://127.0.0.1:8445`, войдите management token и заполните «Сеть», «Publisher» и
«Клиенты» только объектами из discovery. После сохранения `config.yaml` перезапустите весь
Custom App. Hot reload и автоматического redeploy нет.

Management-контейнер создаст `/state/releases.sqlite3` после старта с валидным config. Reset
`/readyz` до первого active release закономерно возвращает `503`.

## Administration dashboard

«Обзор» показывает Publisher и каждый клиент отдельно:

- `connected/disconnected/identity conflict` вычисляется из live TrueNAS sessions;
- `mapped release` проверяется по extent path, ZFS origin, managed properties и `@clean`;
- `updated` означает, что все volumes клиента mapped на active release;
- connection status не подменяет version status.

«Релизы» показывает snapshots, mapped clients и managed clone dependencies. Неактивный release
помечается «не используется mappings» только после обновления всех настроенных клиентов. Это
кандидат для ручной проверки, а не разрешение на удаление. Service не содержит delete API и
никогда автоматически не удаляет releases, snapshots или clones.

## Publisher PC

После сохранения config и restart скачайте на «Обзоре» revision-pinned `publisher.json` и
перенесите его на Publisher. В elevated Windows PowerShell 5.1:

```powershell
./Install-IscsiReleasePublisher.ps1 -ManifestSourcePath ./publisher.json
```

Перед созданием release:

```powershell
C:\ProgramData\IscsiResetPublisher\Publish-IscsiRelease.ps1 -Action Disconnect
```

Helper требует ровно одну master session, сверяет полный набор дисков по NAA, сохраняет pending
state, переводит доказанные диски offline и отключает target. После исчезновения Publisher
session панель разрешит «Создать релиз».

Stage создаёт snapshots и оставляет release staged. Проверьте строку release и введите точное
`ACTIVATE <release>`. Activation повторно проверяет snapshots, target/LUN, extents и отсутствие
Publisher session, затем атомарно меняет active pointer.

После activation:

```powershell
C:\ProgramData\IscsiResetPublisher\Publish-IscsiRelease.ps1 -Action Reconnect
```

Helper подключает target с `IsPersistent=false`, проверяет весь NAA-набор и только затем
переводит диски online. Он не содержит API URL, token, PFX или client certificate.

Если `Disconnect` завершился ошибкой после записи pending state, сначала устраните причину и
выполните `-Action Reconnect` с тем же manifest. Helper сверит revision/NAA, вернёт только
доказанные диски online и удалит pending state лишь после полной проверки.

При incomplete release панель предлагает «Продолжить» и повторно использует исходный request
ID. Частичная ошибка не меняет active release и оставляет master extents выключенными.

## Игровые ПК

Reset-клиент и его API-контракт не изменены:

```powershell
./Install-IscsiResetClient.ps1 \
  -ClientToken "<RAW_CLIENT_TOKEN>" \
  -CaCertificatePath ./reset-ca.crt
```

Клиент получает только portal, собственный target и
`{lun, disk_unique_id, drive_letter, label}`. Release name, snapshot paths и чужие targets ему
не выдаются. Login всегда `IsPersistent=false`. Скрипт не выполняет provisioning-команды и при
ошибке отключает только session, созданную текущим запуском.

## API и CLI

Reset API `https://<SAN-IP>:8443`:

- `GET /healthz`, `GET /readyz`;
- `GET /v1/client`;
- `POST /v1/validate`;
- `POST /v1/prepare`.

Same-origin Management API доступен только после SSH tunnel и cookie login:

- `POST/DELETE /v1/management/session`;
- `GET /v1/management/status`, `/discovery`, `/config`, `/dashboard`, `/releases`;
- `POST /v1/management/config/validate`;
- `PUT /v1/management/config`;
- `POST /v1/management/tokens`;
- `POST /v1/management/releases/stage`;
- `POST /v1/management/releases/{release}/activate`;
- `GET /v1/management/publisher/manifest`.

CLI:

```text
serve-reset
serve-management
config validate
token generate <client>
management-token generate
releases validate|audit|list
```

## Проверка разработки

```bash
python -m pip install -e '.[test]'
ruff check src tests
pytest -q
docker compose config --quiet
docker compose up --build --abort-on-container-exit --exit-code-from windows-simulation
docker compose down --volumes
```

На Windows PowerShell 5.1:

```powershell
Invoke-Pester .\powershell\tests -Output Detailed -CI
```

Mock/Compose не доказывают работу реального TrueNAS, NTFS, certificates или Windows
PowerShell 5.1. Физические проверки перечислены в `TEST-PLAN.md`, фактически выполненное — в
`VERIFICATION.md`.
