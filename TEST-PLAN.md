# Механический тест-план v0.5.1

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
7. Повторить `Reconnect` без зарегистрированного локального объекта master target. Helper
   должен обновлять точный portal до появления IQN, не требуя ручного Refresh. При искусственном
   timeout pending state и offline-диски должны сохраниться.
8. Повторить Reconnect с другой revision, неверным NAA и неожиданной session. Pending state
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
3. На Windows без зарегистрированного `MSFT_iSCSITarget` для client IQN запустить задачу без
   ручного Refresh в iSCSI Initiator. После `prepared` должны появиться
   `target_discovery_started`, затем `target_discovered`; скрипт обязан обновить точный portal,
   дождаться target и подключить его раньше 60-й проверки. Повторный `/v1/prepare` во время
   ожидания не допускается.
4. Занять одну желаемую букву внешним тестовым диском. Повтор должен завершиться кодом `40`,
   отключить только созданную session и не менять букву внешнего диска. Проверить этапы и
   сведения о дисках в `C:\ProgramData\IscsiReset\logs\reset.jsonl`.
5. Создать marker в master, выполнить полный release workflow и загрузить тестовый игровой ПК.
6. Создать на client clone локальный marker и перезагрузить ПК. Master marker должен остаться,
   client marker — исчезнуть после проверенного rollback к `@clean`.
7. Одновременно загрузить два клиента и сверить их target, LUN, NAA и clone paths. Targets и
   clones не должны пересекаться.
8. Проверить fail-closed поведение при неверном token/source IP, активной session, неверном NAA,
   неполном release mapping, неправильном origin и сбое после mutation.
9. Перезапустить оба контейнера и redeploy App с теми же mounts. Active release и dashboard
   должны сохраниться.
10. На копии стенда убрать/повредить SQLite. Reset `/readyz` и management mutations должны
   вернуть ошибку; Windows не должен подключить промежуточный набор LUN.
11. После ошибки, возникшей уже после нового login, задержать исчезновение exact client session
    на несколько секунд. Helper должен ждать до 15 секунд и при необходимости один раз повторить
    disconnect только для точного target IQN. Проверить `target_disconnected_after_error` лишь
    после подтверждённого исчезновения; постоянно остающаяся session должна дать
    `target_disconnect_failed` без optimistic `ready`.

## 7. Epic Games manifest sync

1. На выделенном Publisher с реальным EGS установить GTA V, Fortnite и GTA V Enhanced,
   распределив их по разным master-томам,
   выбрав для Fortnite отличающийся набор компонентов/текстур. Добавить третий произвольно
   названный том без EGS-игр. Буквы и полные пути на Publisher и тестовом клиенте должны
   совпадать.
2. Сначала повторно установить оба helper с `-EpicGamesManifestSync Enabled`, затем отдельно с
   `Aggressive`. Проверить защищённые schema 2 `egs-sync.json` и обратное чтение schema 1; при
   `Disabled` Publisher не должен создавать bundle, а клиент — закрывать EGS или менять файлы.
   Для aggressive scheduled task execution limit должен быть 20 минут, для остальных — 5.
3. Запустить установленные client и Publisher helper отдельным `powershell.exe -File` без
   явного `-EgsSyncConfigPath`. Оба должны загрузиться без parameter-binding ошибки и выбрать
   соседний `egs-sync.json`. Повторить с явным произвольным безопасным путём и убедиться, что
   override не заменяется default-значением.
4. Открыть реальный EGS и выполнить Publisher `Disconnect`. Проверить graceful close до 15
   секунд и forced close оставшихся `EpicGamesLauncher`/`EpicWebHelper`. На каждом master-томе
   должен существовать `.iscsi-reset\egs-manifests.v2.json`; старый helper-generated v1 bundle
   должен отсутствовать, а третий v2 bundle — иметь пустой `manifests`. SHA-256/Base64 обязаны
   воспроизводить точные исходные `.item`; hashes `.manifest`/`.mancpn` должны совпасть, а полная
   Publisher-регистрация каждой игры — содержать только шесть разрешённых полей.
5. Проверить EGS-authored 31- и 32-символьные hex `InstallationGuid`; точные `.item` и
   `.egstore\<InstallationGuid>.manifest` должны приниматься. Отсутствующий у Fortnite
   `.mancpn` допустим, но существующий `.mancpn` обязан быть валидным JSON с тем же `AppName`.
6. Поочерёдно подменить на копии стенда installation ID, install path, hashes `.item`,
   `.manifest` и `.mancpn`, `config_revision`, `volume_name`, обязательный `.manifest`,
   существующий `.mancpn` и executable. Publisher должен отказать до
   pending/offline/disconnect; client должен записать `egs_manifest_sync_warning`, сохранить
   проверенную session, затем записать `ready` без Epic success-событий и текста исключения.
7. Удалить EGS с клиента, установить Launcher заново, не начинать загрузки и выполнить reset.
   До запуска EGS должны существовать три точных `.item`, managed-state и минимальный
   `LauncherInstalled.dat` с GTA V, Fortnite и GTA V Enhanced. Ожидаемый порядок:
   `egs_launcher_registration_sync` → `egs_manifest_sync_ready` → `ready`; все три игры должны
   показать `Launch`.
8. Проверить первый reset с unmanaged Fortnite того же GUID/пути/build, но изменённым EGS
   полем `BaseURLs`. Helper должен архивировать исходные bytes, записать точный bundle,
   создать managed-state и завершить последовательностью `egs_registration_takeover` →
   `egs_launcher_registration_sync` → `egs_manifest_sync_ready` → `ready`.
9. Повторить с локальным Fortnite на системном диске, другим GUID и несовпадающими/дублированными
   записями `LauncherInstalled.dat`. Helper должен сохранить точные резервные копии под
   `egs-displaced-registrations`, удалить только старую регистрацию, оставить каталог и marker
   локальной игры, одну совпадающую сетевую запись и все посторонние приложения/поля.
   Повреждённый локальный JSON и целевой GUID-файл другого AppName должны дать
   `egs_manifest_sync_warning`, сохранить session и завершиться `ready`.
10. Удалить или повредить Publisher `LauncherInstalled.dat`, создать дубли и несовпадающие
   path/version. `Disconnect` должен продолжиться с предупреждением, bundle — получить
   `launcher_registration: null`, а клиент — ненулевой `item_only_fallback_count` без создания
   новой записи. Повторить с incomplete-флагами и непустыми `bps`/`Pending`: выпуск разрешён,
   но `incomplete_warning_count` ненулевой.
11. Удаление управляемой игры из нового bundle должно удалить только её прежний managed `.item`;
   посторонняя локальная EGS-игра и её bytes должны сохраниться.
12. Имитировать отказ после первой записи v2 bundle и после удаления первого v1 bundle
   Publisher. Повторный `Disconnect` должен согласовать весь набор заново. На клиенте
   имитировать отказ после первой замены `.item` и после создания нового `LauncherInstalled.dat`:
   проверенный rollback должен восстановить все bytes, managed-state и `LauncherInstalled.dat`,
   а следующий запуск — успешно завершить транзакцию. Отдельно восстановить оставшийся journal
   v1 от v0.4.6; при искусственно неполном rollback журнал должен сохраниться, а helper —
   записать warning и `ready`, оставив session подключённой.
13. Активировать старый release только с v1: client в режиме `Enabled` должен записать
   `egs_manifest_sync_warning`, сохранить session и завершиться `ready` без Epic success-событий.
14. Выполнить полный Publisher → stage → activate → client workflow для трёх игр. На
   актуальном release EGS должен показать `Launch`. На старом release он должен показать
   `Update`, а не `Install`; Auto Update сетевых игр должен быть отключён штатным переключателем
   EGS, и загрузка не должна начаться автоматически.
15. На release с совпадающим build повторно загрузить клиента и проверить отсутствие полной
   загрузки. Отдельно подтвердить, что различие размера Fortnite объясняется сохранёнными
   `InstallTags`/компонентами, а не реконструкцией `.item`.
16. В режиме `Aggressive` проверить Publisher snapshot всего
    `C:\ProgramData\Epic\EpicGamesLauncher\Data`, точных bytes полного
    `LauncherInstalled.dat` и opaque shared-базы
    `C:\ProgramData\Epic\EpicOnlineServicesShared\InstallHelper\InstalledItems`: anchor —
    первый том manifest, `egs-state.v4.zip`/index находятся только на нём, а
    `egs-manifests.v4.json` на каждом из трёх томов содержит один сохранённый ordered volume
    set и совпадающие hashes/размеры. На клиенте тот же case-sensitive набор должен приниматься
    при обратном порядке LUN/JSON; локальный системный `C:` в сравнении не участвует. V1–v3
    helper bundles/archive должны быть удалены только после полной проверки v4-набора.
17. Добавить неизвестные файлы/JSON-поля и задать отличающиеся Publisher/client attributes и
    UTC timestamps. Проверить точные paths, размеры и SHA-256 при локальной NTFS metadata без
    Publisher ACL/SID. Поочерёдно внедрить изменённые bytes/размер, reparse point,
    traversal, различающийся только регистром collision, более 100 000 файлов, более 1 GiB
    суммарно и файл более 512 MiB: Epic sync должен остановиться с warning, но проверенная
    session должна сохраниться и helper должен записать `ready`.
18. Подключить клиент только с подмножеством томов, добавить лишний, пустой, дублированный и
    отличающийся только регистром logical volume, а также указать anchor отсутствующего тома.
    Каждый случай должен записать `egs_manifest_sync_warning`, сохранить session и не менять
    локальные ProgramData/shared DB. Отдельно активировать v2 и v3 release при aggressive config
    с тем же ожиданием; все случаи завершаются `ready` без Epic success-событий.
    Полный v4-набор в любом порядке должен дать `egs_eos_install_db_sync_ready` →
    `egs_programdata_sync_ready` → `egs_manifest_sync_ready` → `ready`.
19. Имитировать сбой Publisher после записи ZIP, index, первого v4 bundle и удаления первого
    v1–v3 helper-файла; pending/offline/disconnect запрещены, retry согласует весь набор. На
    клиенте имитировать сбои после swap shared-базы, directory swap, замены
    `LauncherInstalled.dat` и managed-state: journal v4 обязан точно восстановить старые bytes,
    а неполный rollback — сохранить journal. Любая клиентская ошибка, включая неполный rollback,
    должна дать warning и `ready` с сохранённой session; следующий запуск выполняет recovery.
20. Проверить recovery оставшихся journals v1–v3, постоянный SHA-addressed backup старых shared
    Install DB, Data и launcher-файла и no-op повторного запуска при точном tree hash. Старое
    локальное состояние не должно удаляться из backup автоматически. Отдельная non-shared база
    `C:\ProgramData\Epic\EpicOnlineServices\InstallHelper\InstalledItems` и старые игровые
    файлы на `C:` должны остаться без изменений.
21. На чистом выделенном клиенте с полным набором томов выполнить физический цикл Publisher →
    stage → activate → reset в `Aggressive`. До запуска EGS проверить три игры и последовательность
    событий; GTA V, Fortnite и GTA V Enhanced должны показать `Launch`.
22. До запуска EGS проверить InstallHelper logs: все три игры должны читаться как `Installed`
    на `E:`, без старых `Incomplete` Fortnite/GTA V на `C:`. Если две игры по-прежнему
    показывают `Продолжить`, сохранить launcher debug logs для отдельного анализа. LocalAppData,
    `webcache*`, account/session, authorization и non-shared EOS state в этот тест не копировать.

## 8. Majestic Launcher settings sync

1. На Publisher и выделенном клиенте из повышенной Windows PowerShell 5.1 переустановить
   helper с `-MajesticLauncherSettingsSync Enabled` под соответствующим игровым пользователем.
   Проверить schema 1 `majestic-sync.json`, точные SID/profile и ACL только для SYSTEM и
   Administrators. Повторить с `Disabled` и убедиться, что startup-задача остаётся SYSTEM.
2. На Publisher полностью проверить игру, задать `prefs.latest.json`,
   `Multiplayer\majestic.json` с тестовым `name`, оба `hashMap_v3.json` и
   `hashMap_v3_RO.json`, `backupMap.json` и реальный `Multiplayer\backup`,
   `lastVisitedServerID=ro3` и `game_disk=E:`, открыть `Majestic Launcher.exe` и выполнить
   `Disconnect` с тремя произвольно названными master-томами.
   Helper должен запросить graceful close, ограниченно завершить остаток процесса и записать
   одинаковый `.iscsi-reset\majestic-launcher-settings.v2.json` на каждый том. Только том с
   буквой из корневого `prefs.latest.json.gameDisk` должен получить постоянный каталог
   `.iscsi-reset\majestic-launcher-backup`; исходный Publisher `Multiplayer\backup` должен стать
   junction на него. Registry `game_disk` временно задать другой буквой и подтвердить, что он
   не влияет на выбор якоря. Затем удалить legacy v1 bundle.
3. Декодировать bundle и сверить точные bytes/размер/SHA-256 четырёх файлов, безопасные
   `version/files` backup map и оба `REG_SZ`. Поля backup index/directory в bundle быть не
   должно. Сверить точные bytes, timestamps и SHA-256 одноразово перенесённого payload только
   на `gameDisk`-томе. SID, исходный `backupDir`,
   путь профиля, Cookies, Session Storage, account и authorization state должны отсутствовать.
4. Выполнить полный Publisher → stage → activate → client reset до входа игрового пользователя.
   SYSTEM должен временно загрузить его `NTUSER.DAT`, записать оба значения через `HKEY_USERS`,
   атомарно заменить малые файлы, создать directory junction на backup payload, последними
   активировать оба hash map и выгрузить hive.
   После входа Launcher должен показать сервер, имя и настройки Publisher без преобразования
   `E:`, а запуск игры не должен повторно читать все 40 GiB для полной проверки.
5. Повторить reset при уже загруженном hive пользователя. `reg load/unload` не вызываются,
   точные файлы и значения сохраняются, а журнал содержит `majestic_settings_sync_ready` перед
   Epic-событиями и `ready` без содержимого файлов, `name` или путей.
6. Поочерёдно удалить bundle одного тома, оставить только v1, изменить его bytes, config
   revision, Base64 и hash каждого payload, а также заблокировать профиль или перезапустить
   Launcher во время sync. Каждый случай должен дать `majestic_settings_sync_warning`, оставить
   проверенную session подключённой и завершиться `ready`.
7. Повторить Publisher `Disconnect` и client reset. Publisher не должен вызывать backup copy
   или `Get-FileHash`, а правильные Publisher/client junction не должны переставляться.
   `backupMap.json` должен сохранить `version/files`, но получить `backupDir` клиентского
   профиля.
8. Имитировать отказ после registry, prefs, `majestic.json`, junction и `backupMap.json`. Во всех
   случаях оба hash map должны отсутствовать, а следующий reset обязан согласовать состояние
   без ручной очистки, активировав `hashMap_v3.json` и `hashMap_v3_RO.json` последними.
9. Переключить Publisher в `Disabled`: следующий Disconnect должен удалить только
   helper-generated Majestic v1/v2 bundles, сохранив постоянный backup payload и Publisher
   junction. Client в `Disabled` не должен закрывать Launcher, читать bundles или менять
   профиль.
10. Имитировать остановку первой миграции после staging, фиксации постоянного каталога,
    переименования исходного backup и создания junction. Retry обязан либо восстановить
    исходный обычный каталог, либо завершить правильный junction и удалить `.staging`/`.previous`.
    Неверный/dangling Publisher junction и staging reparse point должны блокировать Disconnect
    до disk offline.

## 9. GTA5RP Launcher и RAGE-MP registry sync

1. На Publisher и выделенном клиенте из повышенной Windows PowerShell 5.1 переустановить
   helper с `-Gta5RpLauncherSettingsSync Enabled` под соответствующим игровым пользователем.
   Проверить schema 1 `gta5rp-sync.json`, точные SID/profile, ACL только для SYSTEM и
   Administrators и startup-задачу под SYSTEM. Повторить с `Disabled`.
2. Создать на Publisher оба обязательных дерева `HKCU\Software\GTA5RPLauncher` и
   `HKCU\Software\RAGE-MP`: вложенные и пустые ключи, default value, `REG_SZ`, `REG_EXPAND_SZ`,
   `REG_BINARY`, `REG_DWORD`, `REG_DWORD_BIG_ENDIAN`, `REG_MULTI_SZ`, `REG_QWORD` и stale
   значения, отсутствующие в эталоне клиента. Выполнить `Disconnect` с тремя произвольно
   названными master-томами без остановки процессов GTA5RP/RAGE-MP.
3. Сверить одинаковый `.iscsi-reset\gta5rp-launcher-settings.v1.json` на всех master-томах,
   `config_revision`, канонические SHA-256 деревьев, типы, длины и Base64 исходных bytes.
   Bundle не должен содержать SID или путь профиля. JSONL не должен содержать имена ключей,
   значений, пути и данные реестра.
4. Выполнить Publisher → stage → activate → client reset до входа игрового пользователя.
   SYSTEM должен временно загрузить `NTUSER.DAT`, одной реальной TxR-транзакцией заменить оба
   дерева, удалить stale subkeys и commit-ить только после внутренней сверки. После входа
   сравнить канонические snapshots и подтвердить запуск GTA5RP/RAGE-MP с сетевыми путями.
5. Повторить reset при загруженном hive. `reg load/unload` не вызываются, результат остаётся
   точным и журнал содержит `gta5rp_settings_sync_ready` после Majestic и до Epic/`ready`.
6. Имитировать сбой перед TxR commit и отдельно конфликт открытого Registry. Оба прежних дерева
   должны сохраниться без частичных изменений; helper пишет `gta5rp_settings_sync_warning`,
   сохраняет iSCSI-session и завершает `ready`. Следующий reset полностью согласует состояние.
7. Поочерёдно удалить bundle одного тома, изменить bytes, config revision, Base64, hash и тип,
   а также создать разные bundles на клиентских томах. Каждый случай должен дать warning и
   `ready` без изменений деревьев.
8. Изменить одно дерево между первым и вторым Publisher snapshot. Публикация должна удалить
   GTA5RP bundle со всех томов и продолжить Disconnect; неподтверждённая очистка обязана
   остановить операцию до disk offline. Режим `Disabled` удаляет только этот bundle.
9. Отдельно выполнить реальный rollback TxR на Windows PowerShell 5.1 и проверить, что до
   commit ни одно из двух старых деревьев не изменяется. Проверку не заменять mock/container
   результатом.

## 10. Один dual-role Publisher/client ПК

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

## 11. Комплект GitHub Release

1. Скачать семь assets: YAML, `image-digest.txt`, `SHA256SUMS` и четыре операторских `.ps1`.
2. Убедиться, что `publisher.json` и тестовые PowerShell-файлы в выпуск не попали.
3. Выполнить `sha256sum --check SHA256SUMS`; проверка YAML, digest-файла и всех четырёх
   скриптов должна завершиться `OK`.
4. Проверить YAML через `docker compose config --quiet`: в нём должны быть ровно два одинаковых
   digest-pinned `image`, два placeholder управляющего IP-адреса TrueNAS и только два сервиса.
5. Проверить, что workflow artifact и GitHub Release содержат одинаковый комплект файлов.
6. На опубликованном tag дождаться Python, Compose и Windows PowerShell 5.1 CI.

## 12. Чек-лист результата

| Проверка | Ожидание | Факт | Статус |
|---|---|---|---|
| Два контейнера | Reset + loopback Management |  | ☐ |
| Management security | Token/cookie/CSRF/Host/Origin |  | ☐ |
| Discovery/service roles | Read-only и mutation keys разделены |  | ☐ |
| Config save | 409/live recheck/SQLite guards/atomic history |  | ☐ |
| Restart revisions | После restart startup = saved |  | ☐ |
| Publisher Disconnect | Exact session/NAA, pending до mutations |  | ☐ |
| Epic Games sync | Exact bundles; любая ошибка warning-only, session/ready сохраняются |  | ☐ |
| Majestic settings sync | 5 small files/REG_SZ, backup junction, both hash maps last |  | ☐ |
| GTA5RP/RAGE-MP sync | Два полных Registry tree, один TxR commit, rollback/retry |  | ☐ |
| Stage | Fail-closed, immutable полный mapping |  | ☐ |
| Incomplete retry | Исходный request ID, без удаления snapshots |  | ☐ |
| Activate до reconnect | Повторная live-сверка и atomic pointer |  | ☐ |
| Publisher Reconnect | Same revision, nonpersistent, exact NAA |  | ☐ |
| Client dashboard | Session отдельно от mapped release |  | ☐ |
| Dual-role ПК | Только одна активная роль, обе стороны fail-closed |  | ☐ |
| Unused criterion | Только кандидат, dependencies показаны |  | ☐ |
| Client reset | Полный доказанный набор LUN |  | ☐ |
| Lost SQLite/API | Fail-closed и stale dashboard |  | ☐ |
