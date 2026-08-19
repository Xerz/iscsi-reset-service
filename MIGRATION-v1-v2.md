# Миграция конфигурации v1 → v2 и deployment v0.2 → v0.3

Автоматической миграции нет: v0.2.0 отклоняет `schema_version: 1`, чтобы устаревший
`active_release` из YAML случайно не переопределил SQLite.

1. Сохранить копию старого YAML и не удалять существующие master snapshots/clones.
2. Удалить из рабочего YAML `active_release`, `releases` и клиентские `release_override`.
3. Из snapshot paths перенести master datasets в `publisher.volumes`:

   ```yaml
   publisher:
     source_ip: 10.20.40.100
     initiator_iqn: iqn.1991-05.com.microsoft:publisher
     target_iqn: iqn.2026-08.lab.games:master
     volumes:
       ssd: {dataset: nvme/masters/games-ssd, extent_id: 10, lun: 0}
       hdd: {dataset: hdd/masters/games-hdd, extent_id: 11, lun: 1}
   ```

4. Добавить `admin_api` и `release_management`, установить `schema_version: 2`.
5. Выполнить `config validate` и развернуть три контейнера. Reset `/readyz` пока ожидаемо `503`.
6. Подключить master target к Publisher PC и выполнить первую публикацию новым PowerShell
   script. Она создаст новый согласованный snapshot set; существующие v1 snapshots не изменятся.
7. После activate проверить `releases list`, затем перезагрузить один тестовый игровой ПК.
8. После успешной миграции `releases audit` покажет старые unattached managed clones. Удалять их
   только вручную после проверки rollback/boot и отдельного backup.

Если v0.1 уже был развёрнут и обязательно требуется сохранить старый release как active без
создания нового snapshot set, остановиться и выполнить отдельную контролируемую import-утилиту;
v0.2.0 намеренно не принимает произвольные существующие snapshots через публичный API.

## Переход с file mount на directory mount

Configurator создаёт `/config/history`, lock и временный файл рядом с `config.yaml`, поэтому
mount одного файла больше не подходит. При обновлении уже установленного Custom App:

1. Остановить Custom App и сохранить отдельные копии текущего `config.yaml` и
   `/state/releases.sqlite3`.
2. Создать host-каталог, например `/mnt/tank/iscsi-reset/config`, принадлежащий
   `10001:10001` с mode `0700`.
3. Перенести текущий файл в
   `/mnt/tank/iscsi-reset/config/config.yaml`, сохранить владельца `10001:10001` и mode `0600`.
4. В Custom App заменить file mount на directory mount `/mnt/tank/iscsi-reset/config:/config`:
   read-only для reset/admin и read-write только для configurator. State directory остаётся
   read-write у admin, read-only у reset/configurator.
5. Создать отдельный read-only TrueNAS discovery user/key и configurator login token digest;
   не переиспользовать runtime API key как discovery credential.
6. Развернуть три одинаковые digest-pinned image references, открыть SSH tunnel и проверить в
   «Статус», что startup revision совпадает с saved revision.
7. Сделать тестовое сохранение без изменения topology, проверить новую immutable-копию в
   `/config/history`, затем штатно перезапустить весь Custom App и снова сверить revisions.

При недоступной/повреждённой SQLite configurator ничего не сохраняет. Отсутствующая SQLite
допускается только при первоначальной установке, когда валидного `config.yaml` ещё нет.
