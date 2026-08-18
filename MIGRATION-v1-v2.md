# Миграция конфигурации v1 → v2

Автоматической миграции нет: v0.2.0 отклоняет `schema_version: 1`, чтобы устаревший
`active_release` из YAML случайно не переопределил SQLite.

1. Сохранить копию старого YAML и не удалять существующие master snapshots/clones.
2. Удалить из рабочего YAML `active_release`, `releases` и клиентские `release_override`.
3. Из snapshot paths перенести master datasets в `publisher.volumes`:

   ```yaml
   publisher:
     source_ip: 10.20.40.100
     initiator_iqn: iqn.1991-05.com.microsoft:threadripper
     target_iqn: iqn.2026-08.lab.games:master
     volumes:
       ssd: {dataset: nvme/masters/games-ssd, extent_id: 10, lun: 0}
       hdd: {dataset: hdd/masters/games-hdd, extent_id: 11, lun: 1}
   ```

4. Добавить `admin_api` и `release_management`, установить `schema_version: 2`.
5. Выполнить `config validate` и развернуть оба контейнера. Reset `/readyz` пока ожидаемо `503`.
6. Подключить master target к Threadripper и выполнить первую публикацию новым PowerShell
   script. Она создаст новый согласованный snapshot set; существующие v1 snapshots не изменятся.
7. После activate проверить `releases list`, затем перезагрузить один тестовый игровой ПК.
8. После успешной миграции `releases audit` покажет старые unattached managed clones. Удалять их
   только вручную после проверки rollback/boot и отдельного backup.

Если v0.1 уже был развёрнут и обязательно требуется сохранить старый release как active без
создания нового snapshot set, остановиться и выполнить отдельную контролируемую import-утилиту;
v0.2.0 намеренно не принимает произвольные существующие snapshots через публичный API.
