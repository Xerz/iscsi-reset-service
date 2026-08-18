# Механический тест-план v0.2.0

Все destructive проверки выполнять сначала на отдельных master/client zvol размером 1 GiB.
Перед началом сохранить конфиг TrueNAS и SQLite state dataset.

## 0. Preflight

1. Выполнить `config validate` и `releases validate`.
2. Проверить, что admin API слушает только management IP:8444, reset API — только
   `10.20.40.10:8443`.
3. Проверить admin API четырьмя запросами:
   - без client certificate — TLS handshake отклонён;
   - с неверным client certificate — TLS handshake отклонён;
   - с правильным certificate, но неверным token — HTTP 401;
   - с правильными credentials с другого management IP — HTTP 403.
4. В Windows сравнить publisher/client IQN с `Get-InitiatorPort`.
5. Записать master/client extent ID, LUN, NAA, serial и disk paths.

## 1. Первый release и безопасный reset

1. На тестовых master-дисках создать `baseline.txt`; перевести диски offline и снова online,
   чтобы проверить штатность процедуры.
2. Запустить `Publish-IscsiRelease.ps1` и подтвердить `ACTIVATE <release>`.
3. Проверить `GET /v1/admin/releases`: созданный release имеет `staged=true` и `active=true`.
4. Загрузить тестовый игровой ПК, проверить наличие `baseline.txt`.
5. Создать на клиентском клоне `delete-me.txt`, перезагрузить ПК.
6. После загрузки проверить: `baseline.txt` существует, `delete-me.txt` отсутствует.

Ожидание: master disks переподключены, клиент видит только полностью reset-набор LUN.

## 2. Stage без activation

1. Добавить в master `STAGED_ONLY.txt`.
2. Запустить publisher и отказаться вводить точную строку activation.
3. Проверить, что master target подключился обратно.
4. Проверить release list: новый release staged, предыдущий остаётся active.
5. Перезагрузить игровой ПК — `STAGED_ONLY.txt` отсутствует.
6. Повторно запустить publisher: он должен использовать pending release, не создавать новый.
7. Ввести точное подтверждение, затем перезагрузить игровой ПК.

Ожидание: после activation файл появляется; Windows reset script и token не менялись.

## 3. Активная publisher session

1. Оставить master target подключённым.
2. Вызвать admin `POST /v1/admin/releases/stage` напрямую с новым request ID.
3. Снова прочитать extent state и release list.

Ожидание: HTTP `409 PUBLISHER_SESSION_ACTIVE`; extent enabled/path, snapshots и active pointer
не изменились.

## 4. Частичный snapshot и восстановление

1. На mock/staging стенде включить failpoint второго `pool.snapshot.create`.
2. Запустить publisher.
3. Проверить: первый snapshot существует, второй отсутствует, release `incomplete`, старый
   release active, оба master extent disabled.
4. Удалить failpoint и повторить publisher с сохранённым `publish.pending.json`.
5. Проверить: недостающий snapshot создан, release staged, оба extent enabled с прежними
   paths/NAA/serial.

Ожидание: первый snapshot не пересоздаётся и ничего автоматически не удаляется.

## 5. Неверный NAA на Threadripper

1. В test config/override временно подменить один NAA из ответа publisher API.
2. Запустить publisher при подключённом master target.
3. Снять состояния всех локальных дисков до/после.

Ожидание: stage не вызван, target не отключён, ни один диск не переведён offline.

## 6. Клиентская изоляция и новый active release

1. Активировать R2 с новым marker-файлом.
2. Одновременно загрузить Chimera и Beast.
3. Проверить target IQN, LUN, NAA и clone paths каждого ПК.
4. Записать разные локальные marker-файлы и снова одновременно перезагрузить оба ПК.

Ожидание: оба видят R2, локальные markers исчезли, клоны/targets не пересеклись.

## 7. Сохранность SQLite

1. Записать active release и checksum `/state/releases.sqlite3`.
2. Перезапустить оба контейнера, затем выполнить App redeploy с тем же state mount.
3. Проверить active release и загрузить один игровой ПК.
4. На отдельной копии стенда убрать/повредить SQLite.

Ожидание: после штатного redeploy active сохраняется; при потере/повреждении БД reset
`/readyz` возвращает 503 и Windows ничего не подключает.

## 8. Чек-лист результата

| Проверка | Ожидание | Факт | Статус |
|---|---|---|---|
| mTLS/token/IP | Все три защиты обязательны |  | ☐ |
| Первый release | Stage + atomic activate |  | ☐ |
| Rollback 1 GiB | baseline есть, mutation нет |  | ☐ |
| Stage без activate | Старый release остаётся active |  | ☐ |
| Publisher session | 409, без mutations |  | ☐ |
| Partial snapshot | Disabled → same-ID recovery |  | ☐ |
| Wrong NAA | Локальные диски не изменены |  | ☐ |
| Новый release | Ленивая миграция на следующем boot |  | ☐ |
| Chimera + Beast | Targets и clones изолированы |  | ☐ |
| Redeploy | Active release сохранён |  | ☐ |
| Lost SQLite | Reset API fail-closed |  | ☐ |
