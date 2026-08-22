# Механический тест-план v0.4.1

Физические и destructive-проверки выполняются только на отдельных master/client zvol размером
1 GiB. Перед началом сохраните конфигурацию TrueNAS и копию `/state/releases.sqlite3`. Никакой
пункт этого плана не разрешает удалять snapshots, clones или releases.

## 0. Preflight

1. Проверить, что Custom App содержит ровно два контейнера: `iscsi-reset-api` и
   `iscsi-reset-management`.
2. Убедиться, что наружу опубликован только reset HTTPS на SAN IP `:8443`, а management HTTP
   привязан к `127.0.0.1:8445`. Порта `8444`, admin TLS и Publisher credentials быть не должно.
3. В обоих контейнерах проверить UID/GID `10001`, read-only root, `cap_drop: ALL`,
   `no-new-privileges`, отсутствие privileged, Docker socket и `/dev/zvol`.
4. Сверить publisher/client IQN с `Get-InitiatorPort`. Записать master/client extent ID, LUN,
   NAA, serial и dataset paths.
5. Убедиться, что discovery key имеет `DATASET_READ`, `SNAPSHOT_READ` и необходимые
   `SHARING_ISCSI_*_READ` роли. Проверить, что без `SNAPSHOT_READ` базовый discovery может
   пройти, но live dashboard fail-closed отклоняется; любой write JSON-RPC этим key должен
   отклоняться.
6. Проверить service key отдельно: read/query и необходимые iSCSI/ZFS mutations доступны
   только ему. Оба API URL должны указывать на management IP TrueNAS, не на loopback и не на
   Publisher NAT/VIP.

## 1. Management UI и начальная настройка

1. С удалённого компьютера убедиться, что прямое соединение к `<TRUENAS_IP>:8445` невозможно.
2. Открыть `ssh -N -L 8445:127.0.0.1:8445 <truenas>` и войти на
   `http://127.0.0.1:8445` management token.
3. Проверить отказ для неверного token, non-loopback Host, неверного Origin и отсутствующего
   CSRF. Cookie должна быть `HttpOnly`/`SameSite=Strict`; framing и внешние assets запрещены.
4. Сверить discovery с TrueNAS: portals, targets/IQN, initiators, extents/NAA/serial/dataset,
   target–extent–LUN и datasets. File/locked extents и clone parents другого pool не должны
   предлагаться.
5. Убедиться, что `pool.dataset.query` с `properties:["keystatus"]` возвращает
   `locked:false` для master zvol и filesystem clone parents. `true` и `null` должны
   исключаться.
6. Имитировать ошибку discovery: authenticated shell остаётся открыт, последняя картина
   отмечена stale, mutations заблокированы. После успешного refresh блокировка снимается.
7. Проверить все шесть разделов, form↔YAML, duplicate keys и однократную выдачу raw client
   token. Raw token не должен появиться в config, browser storage, logs или audit.
8. Сохранить initial schema v3 config. Проверить mode `0600`, копию в `/config/history`, новый
   saved revision, прежний startup revision и обязательный restart banner.
9. До restart убедиться, что stage/activate заблокированы. Перезапустить весь Custom App и
   проверить равенство startup/saved revisions.
10. Повторить save со старым `base_revision`, с исчезнувшим TrueNAS object, недоступной и
    повреждённой SQLite. Файл и history не должны быть повреждены.

## 2. Publisher helper: безопасное отключение

1. Скачать из панели новый revision-pinned `publisher.json` и скопировать вместе с общим
   `Publish-IscsiRelease.ps1` на тестовый Publisher PC.
2. При подключённом ровно один раз master target выполнить `-Action Disconnect`.
3. Проверить перед mutations полный target/session и набор дисков по нормализованным NAA.
4. После выполнения проверить: pending state записан, только доказанные master disks offline,
   target disconnected, manifest revision сохранён.
5. Повторить с неверным NAA, лишним/отсутствующим диском, нулём и двумя sessions. Ни один диск
   не должен измениться.
6. Имитировать сбой после первого offline. Helper должен завершиться ошибкой, pending state
   сохраниться, а повторный запуск не должен затронуть посторонние диски.

## 3. Stage и activation до reconnect

1. При подключённом Publisher проверить, что кнопка создания release заблокирована и dashboard
   показывает точную session либо identity conflict.
2. После успешного `Disconnect` обновить dashboard: Publisher должен быть `disconnected`, без
   partial-match conflict.
3. Нажать «Создать релиз». Проверить snapshots каждого publisher volume, полный immutable
   mapping в SQLite, staged state и включённые master extents.
4. До reconnect ввести точную строку `ACTIVATE <release>`. Проверить повторную сверку snapshots,
   topology, enabled extents, отсутствия Publisher session, config revision и SQLite.
5. Убедиться, что active pointer изменился одной SQLite-транзакцией. Publisher пока отображается
   disconnected; автоматического rollback нет.
6. Выполнить `-Action Reconnect` с тем же manifest revision и pending state. Проверить
   непостоянную session, точный набор NAA, перевод дисков online только после полной сверки и
   удаление pending state.
7. Повторить Reconnect с другой revision, неверным NAA и неожиданной session. Pending state
   должен сохраниться, посторонние диски не меняются.

## 4. Incomplete release и reconciliation

1. На mock/staging стенде включить failpoint второго `pool.snapshot.create`.
2. Начать stage и проверить: первый snapshot существует, второй отсутствует, release
   `incomplete`, прежний release active, master extents disabled.
3. Убрать failpoint. Панель должна показывать «Продолжить», а не создавать новый release.
4. Повторить action: должен использоваться сохранённый request ID, первый snapshot не
   пересоздаётся, недостающий создаётся, release становится staged.
5. Имитировать Publisher reconnect до activation. Activation обязана отклониться без изменения
   active pointer.

## 5. Dashboard клиентов и releases

1. Для каждого клиента отдельно сверить точную session classification по source IP, initiator
   IQN и target IQN. Частичное совпадение должно отображаться как conflict.
2. Сверить target/LUN, extent path, managed ZFS properties, origin snapshot и `@clean` для
   каждого volume.
3. Проверить состояния `unprepared`, `partial`, `outdated` и `active`; connected должен
   отображаться отдельно от версии.
4. После activation нового release перезагрузить один клиент. Он должен стать active, а
   остальные остаться outdated независимо от connection state.
5. Только после перехода всех настроенных клиентов на active release проверить badge старого
   release «кандидат для ручной очистки». Active/incomplete release или release с текущим
   client mapping такого badge иметь не должен.
6. Сверить существование snapshots и число clone dependencies через TrueNAS. Никакой delete
   button/API и автоматического удаления быть не должно.
7. Отключить TrueNAS API или повредить SQLite: последняя картина остаётся stale, stage/activate
   заблокированы, login не сбрасывается.

## 6. Client reset и сохранность состояния

1. Создать marker в master, выполнить полный release workflow и загрузить тестовый игровой ПК.
2. Создать на client clone локальный marker и перезагрузить ПК. Master marker должен остаться,
   client marker — исчезнуть после проверенного rollback к `@clean`.
3. Одновременно загрузить два клиента и сверить их target, LUN, NAA и clone paths. Targets и
   clones не должны пересекаться.
4. Проверить fail-closed поведение при неверном token/source IP, активной session, неверном NAA,
   неполном release mapping, неправильном origin и сбое после mutation.
5. Перезапустить оба контейнера и redeploy App с теми же mounts. Active release и dashboard
   должны сохраниться.
6. На копии стенда убрать/повредить SQLite. Reset `/readyz` и management mutations должны
   вернуть ошибку; Windows не должен подключить промежуточный набор LUN.

## 7. Чек-лист результата

| Проверка | Ожидание | Факт | Статус |
|---|---|---|---|
| Два контейнера | Reset + loopback Management |  | ☐ |
| Management security | Token/cookie/CSRF/Host/Origin |  | ☐ |
| Discovery/service roles | Read-only и mutation keys разделены |  | ☐ |
| Config save | 409/live recheck/SQLite guards/atomic history |  | ☐ |
| Restart revisions | После restart startup = saved |  | ☐ |
| Publisher Disconnect | Exact session/NAA, pending до mutations |  | ☐ |
| Stage | Fail-closed, immutable полный mapping |  | ☐ |
| Incomplete retry | Исходный request ID, без удаления snapshots |  | ☐ |
| Activate до reconnect | Повторная live-сверка и atomic pointer |  | ☐ |
| Publisher Reconnect | Same revision, nonpersistent, exact NAA |  | ☐ |
| Client dashboard | Session отдельно от mapped release |  | ☐ |
| Unused criterion | Только кандидат, dependencies показаны |  | ☐ |
| Client reset | Полный доказанный набор LUN |  | ☐ |
| Lost SQLite/API | Fail-closed и stale dashboard |  | ☐ |
