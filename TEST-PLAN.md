# Механический тест-план v0.4.4

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

1. На русской Windows PowerShell 5.1 запустить `Install-IscsiResetClient.ps1` без token в
   аргументах. Проверить скрытый ввод token, default и явно заданный `ResetApiIp`, а также ACL
   каталога и `client.token` только для SID `S-1-5-18` и `S-1-5-32-544`.
2. На первом подключении новых клонов разрешить Windows автоматически переставить ожидаемые
   буквы двух client-дисков. Запустить задачу и проверить, что скрипт по NAA распознаёт оба
   диска, снимает конфликтующие access paths только с них, назначает конфигурационные буквы и
   оставляет session подключённой.
3. Занять одну желаемую букву внешним тестовым диском. Повтор должен завершиться кодом `40`,
   отключить только созданную session и не менять букву внешнего диска. Проверить этапы и
   сведения о дисках в `C:\ProgramData\IscsiReset\logs\reset.jsonl`.
4. Создать marker в master, выполнить полный release workflow и загрузить тестовый игровой ПК.
5. Создать на client clone локальный marker и перезагрузить ПК. Master marker должен остаться,
   client marker — исчезнуть после проверенного rollback к `@clean`.
6. Одновременно загрузить два клиента и сверить их target, LUN, NAA и clone paths. Targets и
   clones не должны пересекаться.
7. Проверить fail-closed поведение при неверном token/source IP, активной session, неверном NAA,
   неполном release mapping, неправильном origin и сбое после mutation.
8. Перезапустить оба контейнера и redeploy App с теми же mounts. Active release и dashboard
   должны сохраниться.
9. На копии стенда убрать/повредить SQLite. Reset `/readyz` и management mutations должны
   вернуть ошибку; Windows не должен подключить промежуточный набор LUN.

## 7. Один dual-role Publisher/client ПК

1. Настроить один клиент с той же полной парой SAN IP/IQN, что у Publisher, но с отдельными
   client target, extent и associations. Убедиться, что обе target имеют точный IQN и тот же
   `/32`, а панель сохраняет конфигурацию.
2. Подключить master target. В карточке клиента должно появиться предупреждение об активной
   роли Publisher с точным target IQN; client prepare обязан завершиться до любых mutations.
3. Полностью отключить master target и запустить client prepare. Должна подключиться только
   client target с клонами.
4. Пока client target подключена, проверить предупреждение у Publisher с именем клиента и
   target IQN. Stage и activation обязаны быть заблокированы до любых mutations.
5. Полностью отключить client target и убедиться, что stage/activation снова разрешаются при
   выполнении остальных условий. Затем подключить master target отдельно.
6. Проверить частичное совпадение только IP, только IQN и постороннюю target: это должна быть
   красная ошибка `identity conflict`, а не ожидаемое предупреждение о другой роли.

## 8. Комплект GitHub Release

1. Скачать семь assets: YAML, `image-digest.txt`, `SHA256SUMS` и четыре операторских `.ps1`.
2. Убедиться, что `publisher.json` и тестовые PowerShell-файлы в выпуск не попали.
3. Выполнить `sha256sum --check SHA256SUMS`; проверка YAML, digest-файла и всех четырёх
   скриптов должна завершиться `OK`.
4. Проверить YAML через `docker compose config --quiet`: в нём должны быть ровно два одинаковых
   digest-pinned `image`, два placeholder управляющего IP-адреса TrueNAS и только два сервиса.
5. Проверить, что workflow artifact и GitHub Release содержат одинаковый комплект файлов.
6. На опубликованном tag дождаться Python, Compose и Windows PowerShell 5.1 CI.

## 9. Чек-лист результата

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
| Dual-role ПК | Только одна активная роль, обе стороны fail-closed |  | ☐ |
| Unused criterion | Только кандидат, dependencies показаны |  | ☐ |
| Client reset | Полный доказанный набор LUN |  | ☐ |
| Lost SQLite/API | Fail-closed и stale dashboard |  | ☐ |
