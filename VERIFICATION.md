# Verification record

## Release preparation v0.5.0 — 2026-08-27

### Физическое подтверждение оператора

- После внедрения постоянного Majestic backup junction оператор проверил актуальную сборку на
  игровом компьютере: Majestic Launcher и игра запускаются, повторная загрузка или полная
  проверка игровых файлов не выполняется. Это подтверждение относится к проверенному
  оператором сценарию и не заменяет остальные Windows/TrueNAS случаи из `TEST-PLAN.md`.

### Изменения выпуска

- README сокращён и переведён на прямые инструкции. Оставлены по одному полному примеру
  установки Publisher и клиента с Epic `Aggressive` и Majestic `Enabled`; 13 диагностических
  случаев оформлены отдельными раскрывающимися блоками.
- Версия проекта повышена до `0.5.0`. Publish workflow требует непустой annotated tag,
  использует его содержимое как release highlights и автоматически добавляет хронологический
  список коммитов после предыдущего semver-тега.

### Проверки подготовки выпуска

- Структурная проверка README — успешно: ровно один вызов каждого установщика, оба содержат
  Epic `Aggressive` и Majestic `Enabled`; 13 пар `<details>/<summary>` сбалансированы, все
  относительные Markdown-ссылки существуют. Обе внешние ссылки на документацию TrueNAS 25.10
  успешно открыты с `curl --location --fail`.
- Версия `0.5.0` совпадает в `pyproject.toml`, package `__version__` и заголовке README;
  `.github/workflows/publish.yml` успешно разобран YAML parser. Алгоритм истории выпуска выбрал
  `v0.4.12` предыдущим semver-тегом и вернул два текущих функциональных коммита в
  хронологическом порядке. `v0.4.12` подтверждён как annotated tag.
- `ruff check src tests` — успешно; `pytest -q -p no:cacheprovider` — **133 passed** за
  1.95 секунды.
- `node --check src/iscsi_reset_service/static/app.js` и
  `node tests/static_connection_presentations.test.mjs` — успешно.
- `docker compose config --quiet` — успешно.
- Локально сгенерированный v0.5.0 TrueNAS YAML успешно прошёл `docker compose config`; в нём
  подтверждены два сервиса, два одинаковых digest-pinned `image` и два management IP
  placeholder.
- Parser всех production/test `.ps1` и полный Pester 5.7.1 в локальном образе
  `mcr.microsoft.com/powershell:7.5-ubuntu-24.04`
  (`sha256:4be726730a1f69796dfc86d2531ddbdf662bebbaa4edc47c4111c2463fe32b9a`) —
  **156 passed, 0 failed, 1 skipped** из 157 за 17.6 секунды. Linux/amd64 PowerShell
  выполнялся через эмуляцию на arm64 Docker host; пропущена Windows-only ACL проверка. Это не
  Windows PowerShell 5.1.
- `docker compose up --build --abort-on-container-exit --exit-code-from windows-simulation` —
  **Interaction suite passed** с версией `0.5.0`; после проверки выполнен
  `docker compose down --volumes`.

## Majestic Launcher verification state v0.4.14 — 2026-08-26

### Реализация

- Существующий opt-in `-MajesticLauncherSettingsSync Enabled` расширен без изменения installer
  config schema, YAML, SQLite и Reset API. Publisher теперь захватывает точные bytes prefs,
  `Multiplayer\majestic.json`, `hashMap_v3.json`, `hashMap_v3_RO.json`, два разрешённых `REG_SZ`
  и проверенную безопасную часть `version/files` из `backupMap.json`.
- Publisher выбирает ровно один anchor только по корневому `prefs.latest.json.gameDisk`, не по
  registry или путям из других файлов. При первой публикации он копирует обычные файлы верхнего
  уровня `Multiplayer\backup` в постоянный
  `<gameDisk>\.iscsi-reset\majestic-launcher-backup`, проверяет длину, SHA-256 и timestamps и
  атомарно заменяет исходный каталог directory junction. Лимиты: 64 файла, 4 GiB на файл,
  8 GiB всего; reparse points и подкаталоги запрещены.
- Правильный Publisher junction становится единственным marker миграции. Повторный Disconnect
  выполняет только быструю проверку цели/размеров и не копирует или хеширует backup. Bundle
  schema 2 одинаков на всех master-томах и больше не содержит backup index/directory; исходный
  `backupDir`, дополнительные поля backup metadata, SID и путь профиля также не попадают.
- Client требует одинаковый валидный v2 на всех своих томах, выбирает anchor только по
  переданному prefs `gameDisk` и создаёт постоянный `Multiplayer\backup` junction на
  `<gameDisk>\.iscsi-reset\majestic-launcher-backup`. Правильный junction не переставляется;
  `backupMap.json` получает клиентский `backupDir` при сохранении безопасных `version/files`.
- Перед mutations удаляются оба verification hash map. Registry, prefs, `majestic.json`,
  junction и `backupMap.json` применяются до `hashMap_v3.json`; `hashMap_v3_RO.json` фиксируется
  последним. Частичный сбой удаляет оба marker и остаётся warning-only, следующий reset
  повторяет согласование. Disabled/обычная capture failure очищает только v1/v2 bundles и
  сохраняет постоянный payload/junction. Неоднозначное состояние миграции, неверный junction
  или неподтверждённая очистка staging блокируют Publisher до offline/disconnect.

### Автоматически проверено

- `ruff check src tests` — успешно; `pytest -q -p no:cacheprovider` — **133 passed** за
  1.70 секунды.
- `node --check src/iscsi_reset_service/static/app.js` и
  `node tests/static_connection_presentations.test.mjs` — успешно.
- Parser всех production/test `.ps1` и полный Pester 5.7.1 в локальном образе
  `mcr.microsoft.com/powershell:7.5-ubuntu-24.04`
  (`sha256:4be726730a1f69796dfc86d2531ddbdf662bebbaa4edc47c4111c2463fe32b9a`) —
  **156 passed, 0 failed, 1 skipped** из 157 за 17.53 секунды. Linux/amd64 PowerShell
  выполнялся через эмуляцию на arm64 Docker host; пропущена существующая Windows-only ACL
  проверка. Majestic-тесты используют малые fixtures и покрывают реальную структуру prefs,
  `gameDisk` независимо от registry, три произвольных тома, exact bytes/timestamps,
  одноразовую миграцию, no-copy/no-hash retry, recovery после commit/rename/junction failure,
  unsafe staging, постоянные Publisher/client junction, marker-last, Disabled и warning/ready.
- `docker compose config --quiet` — успешно.
- `docker compose up --build --abort-on-container-exit --exit-code-from windows-simulation` —
  **Interaction suite passed**; после проверки выполнен `docker compose down --volumes`.

### Ожидает Windows/TrueNAS стенда

- Полный Pester на настоящем Windows PowerShell 5.1 и отдельная проверка создания/замены
  directory junction под Publisher helper и startup-задачей `SYSTEM`, включая одноразовый
  переход со старого обычного backup-каталога размером около 2.5–3 GiB и отсутствие повторного
  копирования/хеширования.
- Физический Publisher → `Disconnect` → stage → activate → client reset с реальными NTFS,
  iSCSI, ZFS/TrueNAS и backup payload. Нужно подтвердить точные bytes четырёх файлов, оба
  `REG_SZ`, сгенерированный `backupMap.json`, доступность backup через junction и восстановление
  clone после следующего reset.
- Первый запуск игры должен подтвердить, что Majestic Launcher принимает оба hash map,
  `backupMap.json` и linked backup payload как состояние завершённой проверки и больше не читает
  все 40 GiB. Mock/Pester/Compose этого поведения Launcher не доказывают.

## Majestic Launcher settings sync v0.4.13 — 2026-08-25

### Реализация

- Publisher и client installers получили независимый opt-in
  `-MajesticLauncherSettingsSync Enabled|Disabled`, по умолчанию `Disabled`. Оба всегда
  сохраняют SID и путь профиля текущего пользователя в защищённый `majestic-sync.json`, а
  startup-задача клиента остаётся под `SYSTEM`.
- Publisher перед `Disconnect` останавливает `Majestic Launcher.exe`, захватывает точные bytes
  `prefs.latest.json` размером не более 1 MiB и два разрешённых `REG_SZ`, затем атомарно пишет
  одинаковый bundle schema 1 на каждый master-том. Disabled удаляет прежние helper-owned
  bundles. Capture/write failure очищает bundles и даёт warning; неподтверждённая очистка
  останавливает flow до pending/offline/disconnect.
- Client после проверки и монтирования полного набора томов требует одинаковый bundle на всех
  своих томах, останавливает Launcher, пишет только через `HKEY_USERS` сохранённого SID,
  временно загружает `NTUSER.DAT` при необходимости и атомарно заменяет prefs после registry
  mutations. Ошибка даёт `majestic_settings_sync_warning`, сохраняет проверенную iSCSI-session
  и не блокирует `ready`; успех даёт `majestic_settings_sync_ready` до Epic-событий и `ready`.
- Bundle не содержит SID, пути профиля, авторизацию или cache. YAML schema, SQLite, storage
  backend и Reset API не менялись.

### Автоматически проверено

- `ruff check src tests` — успешно.
- `pytest -q -p no:cacheprovider` в Python 3.12 venv — **133 passed** за 1.75 секунды.
- PowerShell parser из закреплённого
  `mcr.microsoft.com/powershell@sha256:042240d57ec9e47e511033b92625a8d95875ee5860af3015992c248b58a8be81`
  прошёл для всех production и test `.ps1`. Контейнер `linux/amd64` выполнялся через эмуляцию
  на локальном `arm64` Docker host.
- Полный Pester 5.7.1 в том же Linux PowerShell-контейнере — **138 passed, 0 failed,
  1 skipped** из 139 за 14.56 секунды. Пропущена только существующая Windows-only проверка
  создания ACL object. Majestic-тесты покрывают точные bytes/REG_SZ, три произвольно названных
  тома, одинаковые и повреждённые bundles, atomic replace/cleanup, loaded/offline user hive,
  partial registry retry, остановку Launcher, Disabled, warning-only startup и порядок событий
  без содержимого prefs в JSONL.
- `docker compose config --quiet` — успешно.
- `docker compose up --build --abort-on-container-exit --exit-code-from windows-simulation` —
  **Interaction suite passed**; после проверки выполнен `docker compose down --volumes`.

### Ожидает Windows/TrueNAS стенда

- Полный Pester на настоящем Windows PowerShell 5.1, включая ACL, Windows Registry provider,
  `reg.exe load/unload`, реальный `NTUSER.DAT` и остановку `Majestic Launcher.exe`.
- Физический Publisher → `Disconnect` → stage → activate → client reset с реальными TrueNAS,
  NTFS и iSCSI. Нужно подтвердить точные bytes prefs, оба `REG_SZ` в профиле игрового
  пользователя, буквальный `game_disk` и выбранные настройки в интерфейсе Majestic Launcher.
- Авторизация, Cookies, Session Storage, cache и состояние проверки игры этой версией намеренно
  не синхронизируются и не объявляются проверенными.

## Epic Games EOS Shared Install DB v0.4.12 — 2026-08-24

### Операторские данные реального клиента и InstallHelper

- Client v0.4.11 успешно выполнил exact-byte aggressive sync: после проверки двух iSCSI-томов
  журнал записал `egs_programdata_sync_ready` для 436 файлов, трёх игр и 116251735 bytes,
  затем `egs_manifest_sync_ready` для трёх manifests и `ready`. Несмотря на доказанное
  совпадение ProgramData/launcher state, GTA V и Fortnite остались в состоянии «Продолжить»;
  GTA V Enhanced показывала `Launch`.
- Publisher InstallHelper 5.6.0 использовал
  `C:\ProgramData\Epic\EpicOnlineServicesShared\InstallHelper\InstalledItems` и перечислил
  Fortnite, GTA V и GTA V Enhanced как `Installed` из `E:\EpicGames\...`.
- Client InstallHelper с тем же shared `installationdbdir` перечислил старые Fortnite
  registrations и GTA V как `Incomplete` из `C:\Program Files\Epic Games\...`. Отдельный
  client InstallHelper с non-shared каталогом
  `C:\ProgramData\Epic\EpicOnlineServices\InstallHelper\InstalledItems` перечислил только
  локальные EOS overlay/service/support artifacts. Это локализует оставшееся различие до
  shared Install DB и одновременно исключает non-shared EOS service DB из переноса.

### Реализация и быстрые локальные проверки

- Aggressive Publisher создаёт bundle v4 на каждом игровом томе и один exact-byte
  `egs-state.v4.zip`/index schema 2 на anchor. Payload включает прежние
  `EpicGamesLauncher\Data`, полный `LauncherInstalled.dat` и opaque shared Install DB. Пустой
  каталог, reparse points, path collisions и прежние file/count/size limits блокируют
  pending/offline/disconnect. После полной повторной проверки удаляются только helper-generated
  v1–v3 bundles/archive.
- Publisher и client ждут отсутствия InstallHelper с точным аргументом
  `--installationdbdir` для shared DB. Client aggressive принимает только v4, атомарно меняет
  все три targets, включает shared DB в SHA-addressed backup и journal v4 и восстанавливает
  прежние bytes при ошибке. Journals v1–v3 остаются совместимыми. Non-shared EOS DB и каталоги
  старых игр не входят в mutations.
- Успешная диагностика теперь упорядочена как `egs_eos_install_db_sync_ready` →
  `egs_programdata_sync_ready` → `egs_manifest_sync_ready` → `ready`.
- PowerShell parser из `mcr.microsoft.com/powershell:7.5-ubuntu-24.04` прошёл для всех
  production и test `.ps1`.
- Профильные Publisher/client Pester 5.7.1 в том же Linux PowerShell-контейнере —
  **103 passed, 0 failed, 0 skipped** за 11.65 секунды. Новые тесты покрывают v4 ZIP/index и
  shared bytes, пустую DB, блокировку активным InstallHelper, порядок событий, отказ от v3,
  journal v4 rollback и сохранность non-shared EOS state; recovery journal v3 также сохранён.
- По согласованному быстрому профилю installer Pester, Ruff, Pytest и Compose локально не
  запускались. После push полный GitHub CI run `32664054849` прошёл успешно для commit
  `76736df6`: Python/Ruff/Pytest/Node, interaction Compose и весь Pester 5.7.1 на Windows
  PowerShell 5.1 завершились без ошибок.

### Физическая приёмка Windows/TrueNAS

- Оператор обновил v0.4.12 helpers в режиме `Aggressive`, создал новый v4 release и подтвердил
  успешный Publisher → stage → activate → client reset на реальном стенде.
- GTA V, Fortnite и GTA V Enhanced распознаны EGS как готовые установки; прежнее состояние
  «Продолжить» для GTA V/Fortnite устранено. На основании этого результата оператор разрешил
  выпуск v0.4.12.
- Отдельные destructive rollback/recovery сценарии из `TEST-PLAN.md` не объявляются пройденными
  этим эксплуатационным подтверждением и остаются самостоятельными стендовыми проверками.

## Epic Games exact bytes без Publisher NTFS metadata v0.4.11 — 2026-08-24

### Операторские данные реального клиента v0.4.10

- После переключения `egs-sync.json` из `Enabled` в `Aggressive` клиент успешно подключил и
  проверил оба iSCSI-диска, прочитал совместимый v3 release и дошёл до финальной проверки
  скопированного ProgramData.
- Запуск завершился `Epic Games aggressive target file metadata verification failed` до
  событий `egs_programdata_sync_ready`/`ready`; EGS сохранил прежнее состояние. В коде эта
  ошибка возможна только после успешной проверки существования, размера и SHA-256 target-файла,
  поэтому расхождение локализовано до Publisher/client NTFS attributes либо timestamps.
- Сообщения о неполном rollback не было. Неизменившееся состояние EGS согласуется с возвратом
  прежнего дерева transaction journal v3, но физический побайтовый аудит rollback отдельно не
  выполнялся.

### Реализация и быстрые локальные проверки

- Client по-прежнему проверяет ZIP/index, безопасные пути, полный file/directory set, размеры,
  SHA-256, collisions и отсутствие reparse points. Готовое дерево атомарно подменяет `Data`, а
  `LauncherInstalled.dat` записывается точными bytes.
- Publisher timestamps/обычные attributes больше не применяются при распаковке и не участвуют
  в target acceptance. Поля остаются синтаксически проверяемой частью index schema v3, поэтому
  существующий release совместим. ACL и NTFS metadata создаются локально.
- Journal v3, SHA-addressed backup и rollback не менялись. Возврат прежнего `Data` сохраняет
  его локальную metadata; metadata прежнего локального launcher-файла по-прежнему
  восстанавливается из journal.
- PowerShell parser закреплённого `mcr.microsoft.com/powershell` прошёл для всех production и
  test `.ps1`.
- Профильный client Pester 5.7.1 в Linux PowerShell-контейнере — **71 passed, 0 failed,
  0 skipped** за 8.33 секунды. Покрыты exact bytes при отличающейся metadata, отказ при
  изменённых bytes, отсутствие Publisher metadata setters в normal aggressive path и
  существующий directory-swap rollback.
- По согласованному быстрому профилю Publisher/installer Pester, Ruff, Pytest и Compose не
  запускались. Push в `main` не ожидает GitHub CI; tag и release не создаются.

### Ожидает Windows/TrueNAS стенда

- обновить только client helper, оставить `mode: aggressive` и повторить reset на существующем
  v3 release;
- подтвердить `egs_programdata_sync_ready` → `egs_manifest_sync_ready` → `ready` и точные bytes
  ProgramData до запуска EGS;
- проверить `Launch` для GTA V, Fortnite и GTA V Enhanced. Если «Продолжить» сохранится после
  доказанного exact-byte sync, следующий этап — launcher debug logs без переноса account/session
  state вслепую.

## Epic Games iSCSI volume-order и cleanup hotfix v0.4.10 — 2026-08-23

### Операторские данные реального клиента v0.4.9

- Reset API подготовил ровно два client volume. Windows успешно проверила два iSCSI-диска с
  буквами `E:` и `D:`, после чего aggressive sync завершился до изменения ProgramData ошибкой
  `Epic Games aggressive sync requires the exact Publisher volume set`.
- В том же запуске немедленная проверка после `Disconnect-IscsiTarget` записала
  `target_disconnect_failed`. Это не доказывает, что Windows окончательно не удалила session:
  v0.4.9 не ожидал асинхронного исчезновения объекта.
- Проверка исходного кода локализовала volume-set отказ до order-sensitive сравнения двух
  JSON-массивов. Локальный системный `C:` не поступает из Reset API и не входит в Publisher v3
  topology; существующий v3 release совместим с hotfix.

### Реализация и быстрые локальные проверки

- Client сравнивает `publisher_volume_names` и имена `prepared.volumes` как точные
  case-sensitive множества. Обратный порядок LUN/букв/JSON принимается; отсутствующий, лишний,
  пустой, дублированный и отличающийся регистром том отклоняется с безопасными количествами без
  имён или путей. Anchor разрешается только exact-match на подключённом iSCSI-томе.
- Publisher flow и bundle schema v3 не менялись: ordered-массив и детерминированный anchor
  сохраняются. ProgramData snapshot, journal v3, API/schema v3, SQLite и backend не менялись.
- Cleanup обращается только к exact target IQN, выполняет до 16 проверок с 15 паузами по одной
  секунде и один ограниченный повтор disconnect после пяти секунд. Успешное событие пишется
  только после подтверждённого отсутствия session; постоянная session сохраняет
  `target_disconnect_failed` и общий fail-closed код.
- PowerShell parser закреплённого `mcr.microsoft.com/powershell` прошёл для всех production и
  test `.ps1`.
- Pester 5.7.1 в том же Linux PowerShell-контейнере — **110 passed, 0 failed, 1 skipped** из 111
  за 12.01 секунды. Новые тесты покрывают обратный порядок двух томов, исключение локального
  `C:`, missing/extra/empty/duplicate/case mismatch, отсутствующий anchor, задержанное удаление
  session, ограниченный retry, постоянную session и оба diagnostic event. Пропущен только
  существующий Windows-only ACL object test.
- По согласованному быстрому профилю локальные Ruff, Pytest и Compose не запускались. Push в
  `main` не ожидает GitHub CI; tag и GitHub Release не создаются.

### Ожидает Windows/TrueNAS стенда

- удалить оставшуюся exact client session, обновить только client helper и повторить reset на
  существующем v3 release без нового Publisher Disconnect/stage/activate;
- подтвердить реальное асинхронное удаление session Windows PowerShell 5.1 и последовательность
  `egs_programdata_sync_ready` → `egs_manifest_sync_ready` → `ready`;
- проверить `Launch` для GTA V, Fortnite и GTA V Enhanced. Эти игровые результаты не следуют из
  mock/Pester и остаются физической приёмкой.

## Epic Games aggressive ProgramData snapshot v0.4.9 — 2026-08-23

### Операторские данные реального EGS client 0.4.8

- Bundle v2 успешно импортировал все три launcher-регистрации с диагностикой `3 / 0 / 0`, но
  GTA V и Fortnite всё равно показали «Продолжить»; GTA V Enhanced показала `Launch`.
- Ручной официальный сброс `webcache*` результата не изменил. Это не доказывает конкретный
  внутренний ключ EGS, но обосновывает следующий ограниченный эксперимент: точный общий
  ProgramData state без LocalAppData, webcache, account/session или authorization state.

### Реализация и быстрые локальные проверки

- Оба installer принимают `Disabled|Enabled|Aggressive` и записывают schema 2 `egs-sync.json`
  с `mode`; schema 1 продолжает читаться. Для aggressive scheduled task limit увеличен до
  20 минут.
- Publisher останавливает EGS и потоково создаёт на первом manifest-томе точный ZIP/index всего
  `EpicGamesLauncher\Data` и полного `LauncherInstalled.dat`. Все тома получают согласованный
  bundle v3 с ordered volume set, anchor и hashes. Reparse points, unsafe/colliding paths и
  лимиты 100 000 files / 1 GiB / 512 MiB проверяются до pending/offline/disconnect; v1/v2
  удаляются только после полной проверки v3.
- Client aggressive требует полный Publisher volume set, проверяет bundle/ZIP/index и каждый
  файл, извлекает staging и через journal v3 заменяет весь `Data`, полный launcher-файл и
  managed-state. Старое состояние получает постоянный SHA-addressed backup; rollback
  восстанавливает прежнее дерево и bytes. Publisher ACL/SID не копируются, целевое дерево
  получает локально наследуемый ACL. Повторный точный tree hash является no-op.
- PowerShell parser закреплённого `mcr.microsoft.com/powershell` прошёл для всех production и
  test `.ps1`.
- Pester 5.7.1 в том же Linux PowerShell-контейнере — **101 passed, 0 failed, 1 skipped** из 102
  за 9.92 секунды. Профиль покрывает schema/mode installers, v2 compatibility, три
  произвольных тома, v3 ZIP/index, unknown files, traversal/collision, extraction, journal v3
  rollback и порядок `egs_programdata_sync_ready` → `egs_manifest_sync_ready` → `ready`.
  Пропущен существующий Windows-only ACL object test.
- По явному запросу оператора локальные Ruff/Pytest/Compose проверки для этой быстрой итерации
  не запускались. Полный GitHub CI запускается push в `main` асинхронно и перед передачей
  результата не ожидается.

### Ожидает Windows/TrueNAS стенда

- повторная установка обоих helper с `-EpicGamesManifestSync Aggressive` на Windows PowerShell
  5.1 и проверка 20-минутного task limit;
- новый Publisher Disconnect → stage → activate → client reset для полного набора трёх томов;
- точная последовательность v3 events и `Launch` для GTA V, Fortnite и GTA V Enhanced до
  любых загрузок;
- физические NTFS directory swap, локальное ACL inheritance, SHA-backup, partial rollback и
  no-op retry. Если «Продолжить» сохранится, следующий этап — сравнение launcher debug logs.

## Epic Games registration bundle v2 v0.4.8 — 2026-08-23

Publisher и client helpers теперь синхронизируют bundle schema 2. Помимо точных байтов `.item`,
bundle связывает release с hashes `.egstore\<InstallationGuid>.manifest` и опционального
`.mancpn`, а также переносит нормализованную регистрацию конкретной игры из шести разрешённых
полей Publisher `LauncherInstalled.dat`. Schema v3, Reset/Management API, SQLite, TrueNAS
backend, managed-state v1 и `egs-sync.json` не менялись.

### Операторские данные реального EGS client 0.4.7

- После полной деинсталляции EGS, чистой установки Launcher, перезагрузки и client reset только
  GTA V Enhanced появилась как готовая к запуску. GTA V и Fortnite показали «Продолжить», а
  нажатие начинало повторную загрузку.
- Это реальное наблюдение не доказывает внутреннюю причину поведения EGS, но показывает, что
  точных `.item` и находящейся в iSCSI snapshot `.egstore` недостаточно для воспроизводимого
  результата после чистой установки Launcher. В v0.4.7 helper не создавал отсутствующие
  игровые записи `LauncherInstalled.dat`.

### Реализация и локальные автоматические проверки

- Publisher извлекает только `InstallLocation`, `NamespaceId`, `ItemId`, `ArtifactId`,
  `AppVersion` и `AppName` из единственной записи с совпадающими AppName, путём и версией.
  Отсутствующий, повреждённый, дублированный или несовпадающий launcher-файл даёт
  `launcher_registration: null` и item-only fallback, но не блокирует Disconnect.
- `bIsIncompleteInstall`, `bNeedsValidation` и непустые `.egstore\bps`/`Pending` сохраняются как
  коды предупреждений. После атомарной записи и повторной проверки полного v2-набора Publisher
  удаляет только helper-generated v1 bundle; частичная ошибка остаётся до
  pending/offline/disconnect и согласуется retry.
- Client принимает только bundle v2, проверяет hashes `.item`, `.manifest` и `.mancpn`, а затем
  в существующей транзакции обновляет `.item`, managed-state и локальный
  `LauncherInstalled.dat`. При чистой установке создаётся минимальный `InstallationList`; при
  merge сохраняются посторонние игры и неизвестные top-level поля. Item-only fallback не
  синтезирует новую игровую запись. Rollback восстанавливает точные исходные bytes и удаляет
  впервые созданный launcher-файл.
- PowerShell parser из `mcr.microsoft.com/powershell:7.5-ubuntu-24.04` — passed для всех
  production и test `.ps1`.
- Pester 5.7.1 в том же Linux PowerShell-контейнере — **95 passed, 0 failed, 1 skipped** из 96
  за 11.21 секунды. Покрыты три игры и произвольные три тома, полный registration import,
  item-only fallback, incomplete warnings, v1 rejection, hash failures, сохранение посторонних
  данных, clean-EGS creation, rollback после `.item`, launcher и managed-state mutations,
  journal v1 recovery, Publisher partial write/v1 removal, retry и порядок событий
  `egs_launcher_registration_sync` → `egs_manifest_sync_ready` → `ready`. Пропущен только
  существующий Windows-only ACL object test.
- `ruff check .` — passed; `pytest -q --cov=iscsi_reset_service --cov-report=term-missing` —
  **133 passed**, total coverage 79%, за 3.66 секунды. JavaScript syntax/static presentation
  tests — passed.
- `docker compose config --quiet` — passed.
- `docker compose up --build --abort-on-container-exit --exit-code-from
  windows-simulation` — passed на локальном arm64 Docker host. Оба сервиса сообщили version
  `0.4.8`, итог — `Interaction suite passed`. Затем выполнен `docker compose down --volumes`;
  контейнеры, сеть и три тестовых volume удалены.
- [CI run `32654190032`](https://github.com/Xerz/iscsi-reset-service/actions/runs/32654190032)
  для commit `a32c09f` прошёл во всех трёх jobs: Python/JavaScript, Compose interaction и
  настоящий Windows PowerShell 5.1 завершились успешно. Pester 5.7.1 на Windows выполнил
  **96 passed, 0 failed, 0 skipped** за 13.17 секунды.

### Ожидает Windows/TrueNAS стенда

- реальный Publisher `Disconnect` с тремя полными регистрациями и создание нового v2 release;
- чистый EGS client с тремя `.item`, managed-state, тремя записями `LauncherInstalled.dat` и
  последовательностью registration sync → manifest sync ready → ready до запуска EGS;
- `Launch` для GTA V, Fortnite и GTA V Enhanced без повторной полной загрузки при совпадающем
  build; старый v1 release должен fail-closed завершиться кодом `40`;
- реальные incomplete-warning/item-only fallback и точный rollback на Windows/NTFS. Если при
  полной v2-регистрации остаётся «Продолжить», следующим отдельным этапом исследуются launcher
  logs и game-specific metadata без слепого переноса webcache, аккаунта или авторизации.

## Epic Games first-run takeover v0.4.7 — 2026-08-23

`EpicGamesManifestSync Enabled` теперь авторитетно переключает уже зарегистрированный AppName
на проверенный сетевой bundle. Локальные каталоги игры не удаляются; вытесненные `.item` и
изменяемый локальный `LauncherInstalled.dat` архивируются по SHA-256. Schema v3,
Reset/Management API, SQLite, TrueNAS backend, bundle v1, managed-state v1 и `egs-sync.json`
не менялись.

### Операторские данные реального Fortnite client

- На реальном игровом ПК `.item` и `LauncherInstalled.dat` одновременно указывали на
  `E:\EpicGames\Fortnite` и build
  `++Fortnite+Release-42.00-CL-56878558-Windows`; регистрации Fortnite на системном диске в
  этих источниках не было.
- SHA-256 локального `.item` отличался от точного payload нового bundle, но сравнение JSON
  показало единственное отличающееся поле `BaseURLs`. GUID, сетевой путь, build и остальные
  проверенные поля совпадали.
- В реальном JSONL отсутствовал `egs_manifest_sync_ready`. Три запуска завершились
  `CLIENT_ERROR` на стадии `egs_manifest_sync` с сообщением
  `Local Epic installation is not managed by iSCSI reset`; созданные session отключались, а
  `egs-managed-apps.v1.json` не создавался. Это подтверждает fail-closed поведение v0.4.6 и
  локализует 10 GiB симптом до успешной синхронизации регистрации.

### Реализация и локальные автоматические проверки

- First-run takeover принимает unmanaged тот же AppName, включая другой GUID/локальный путь и
  отличие только `BaseURLs`. Целевой GUID-файл другого AppName по-прежнему отклоняется.
- Transaction journal v2 восстанавливает `.item`, managed-state и `LauncherInstalled.dat`;
  recovery оставшегося journal v1 от v0.4.6 сохранён. Архив создаётся и проверяется до замены
  регистрации, а unrelated AppName/поля и marker локальной игры сохраняются.
- PowerShell parser из `mcr.microsoft.com/powershell:7.5-ubuntu-24.04` — passed для всех
  production и test `.ps1`.
- Pester 5.7.1 в том же Linux PowerShell-контейнере — **87 passed, 0 failed, 1 skipped** из 88.
  Покрыты `Enabled`/`Disabled`, BaseURLs-only adoption, локальный другой GUID/путь,
  `LauncherInstalled.dat` missing/matching/duplicate/invalid, архивы, посторонние игры,
  target-file collision, изменение launcher-файла после planning, rollback после manifest и
  launcher mutations, retry, journal v1 и порядок `egs_registration_takeover` →
  `egs_manifest_sync_ready` → `ready`. Пропущен только
  существующий Windows-only ACL object test.
- `ruff check src tests` — passed; `pytest -q` — **133 passed** за 1.96 секунды;
  JavaScript syntax/static presentation tests — passed.
- `docker compose config --quiet` — passed.
- `docker compose up --build --abort-on-container-exit --exit-code-from
  windows-simulation` — passed на локальном arm64 Docker host. Оба сервиса сообщили version
  `0.4.7`, итог — `Interaction suite passed`. Затем выполнен `docker compose down --volumes`;
  контейнеры, сеть и три тестовых volume удалены.
- [CI run `32650509069`](https://github.com/Xerz/iscsi-reset-service/actions/runs/32650509069)
  для commit `679b155` прошёл во всех трёх jobs: Python/JavaScript, Compose interaction и
  настоящий Windows PowerShell 5.1 с Pester 5.7.1 завершили свои verification steps успешно.

### Ожидает Windows/TrueNAS стенда

- повтор реального client reset с событиями takeover → sync ready → ready и точным
  managed-state;
- подтверждение, что EGS показывает сетевой путь, локальные файлы сохранены и актуальный
  Fortnite build показывает `Launch` без загрузки 10 GiB;
- если после доказанно успешной регистрации остаётся `Update`, отдельная проверка фактических
  `.egstore`/компонентов snapshot без маскировки настоящего обновления.

## Epic Games manifest sync v0.4.6 — 2026-08-23

В рабочем дереве добавлена локальная opt-in синхронизация точных Epic Games `.item` между
Publisher и клиентом. Schema v3, Reset/Management API, SQLite и TrueNAS backend не менялись.

### Операторские данные реального EGS Publisher

- Реальный `Disconnect` остановился до pending/offline/disconnect на первоначальной проверке
  Fortnite `InstallationGuid` как ровно 32 hex-символов. Диски остались подключены, то есть
  fail-closed порядок mutations подтвердился.
- EGS-authored `.item` имел точное имя `6CBCB32C02D40E72A7D7C61F8AB8A4A.item` и такое же
  31-символьное значение `InstallationGuid`. Непустой `<InstallationGuid>.manifest`
  присутствовал, а точный `<InstallationGuid>.mancpn` отсутствовал.
- Эти данные опровергают две первоначальные гипотезы формата: фиксированную длину 32 и
  обязательность `.mancpn` для каждой игры. Hotfix принимает безопасный hex ID длиной 16–64,
  сохраняет точное совпадение `.item`/`.manifest` и строго проверяет `.mancpn`, когда он есть.

### GitHub Actions regression после EGS hotfix

- В [CI run `32639018247`](https://github.com/Xerz/iscsi-reset-service/actions/runs/32639018247)
  для commit `dbb62a3` Python и interaction jobs прошли, а Windows PowerShell 5.1/Pester
  завершился с **74 passed, 3 failed** из 77. Два Publisher-теста обнаружили, что Windows
  PowerShell 5.1 пишет UTF-8 BOM через `Set-Content -Encoding UTF8`, который прежний разбор
  exact-byte `.item` не принимал. Client-тест обнаружил отличие PS 5.1 при чтении `.Count`
  у scalar manifest entry.
- Текущий hotfix удаляет только начальный `U+FEFF` из строки перед `ConvertFrom-Json`; исходные
  байты не меняются и по-прежнему используются для SHA-256 и Base64 bundle. Publisher/client
  regression fixtures теперь детерминированно включают BOM, а managed-state assertions явно
  оборачивают `manifests` в массив.
- [CI run `32641184477`](https://github.com/Xerz/iscsi-reset-service/actions/runs/32641184477)
  для hotfix commit `43cf7f7` прошёл во всех трёх jobs. На GitHub-hosted Windows Server 2025
  настоящий Windows PowerShell 5.1 с Pester 5.7.1 выполнил **77 passed, 0 failed, 0 skipped**,
  включая обе прежние Publisher ошибки и client managed-state assertion.

### Windows PowerShell 5.1 parameter default regression

- На реальном игровом ПК прямой запуск установленного `Reset-And-Connect.ps1` через
  `powershell.exe -File` без `-EgsSyncConfigPath` завершился при parameter binding: выражение
  `Join-Path $PSScriptRoot "egs-sync.json"` получило пустой `Path`. Ошибка произошла до main,
  логирования, iSCSI login и disk mutations.
- Hotfix убирает `$PSScriptRoot` из default-выражений client/Publisher runtime helper и обоих
  installer. Соседний `egs-sync.json` либо companion script вычисляется после `param`; явные
  `-EgsSyncConfigPath`, `-ClientScriptPath` и `-PublisherScriptPath` сохраняются без изменений.
  До установки hotfix client можно запустить с явным
  `-EgsSyncConfigPath "C:\ProgramData\IscsiReset\egs-sync.json"`.
- [CI run `32647261549`](https://github.com/Xerz/iscsi-reset-service/actions/runs/32647261549)
  для hotfix commit `c5f68ce` прошёл во всех трёх jobs. Windows Server 2025 с Windows
  PowerShell 5.1/Pester 5.7.1 выполнил **82 passed, 0 failed, 0 skipped**; оба runtime helper
  успешно стартовали дочерним `powershell.exe -File` без явного EGS config path.

### Локальные автоматические проверки

- PowerShell parser из `mcr.microsoft.com/powershell:7.5-ubuntu-24.04` — syntax passed для всех
  production и test `.ps1`.
- Pester 5.7.1 в том же Linux PowerShell-контейнере — **81 passed, 0 failed, 1 skipped** из 82.
  Покрыты запуск обоих runtime helper отдельным `pwsh -File` без явного EGS config path,
  отсутствие `$PSScriptRoot` во всех parameter defaults, default/override path, Enabled/Disabled,
  graceful/forced EGS close, GTA/Fortnite с разными `InstallTags`, BOM-prefixed 31-символьный
  Fortnite ID без `.mancpn`, 32-символьный ID с `.mancpn`, три произвольных тома и пустой
  bundle, неверные ID/path/hash/config revision, unmanaged `AppName`, сохранение BOM-prefixed
  посторонней игры, частичная запись, rollback и успешный retry. Пропущен существующий
  Windows-only ACL object test.
- `ruff check src tests` — passed.
- `pytest -q` — **133 passed** за 2.03 секунды.
- `docker compose config --quiet` — passed.
- `docker compose up --build --abort-on-container-exit --exit-code-from windows-simulation` —
  passed на локальном arm64 Docker host: оба сервиса сообщили version `0.4.6`, итог —
  `Interaction suite passed`. После проверки выполнен `docker compose down --volumes`;
  контейнеры, сеть и три тестовых volume удалены.

### Ожидает физического TrueNAS/Windows стенда

- автоматическое graceful/forced закрытие реального EGS в Windows PowerShell 5.1;
- полный Publisher → stage → activate → client workflow для GTA и Fortnite с реальными NTFS
  LUN и `.egstore` metadata;
- актуальный release показывает `Launch`, старый — `Update`, а не `Install`;
- при совпадающем build нет повторной полной загрузки, а сохранённые `InstallTags` отражают
  выбранные компоненты Fortnite;
- ACL managed-state, транзакционный rollback и восстановление журнала после реального сбоя
  Windows/NTFS.

## Ожидание Windows iSCSI target после `prepare` — 2026-08-23

### Операторские данные реальной Windows и TrueNAS

- На реальном игровом ПК Reset API стал доступен, загрузил client config и завершил `prepare`
  двух томов. Через 82 мс Windows PowerShell завершился на стадии `connect`: локальный объект
  `MSFT_iSCSITarget` с ожидаемым `NodeAddress` ещё отсутствовал.
- После ручного **Refresh** в панели Microsoft iSCSI Initiator target появился. Повторный ручной
  запуск scheduled task подключил диски, и следующая перезагрузка также завершилась успешно.
- Это подтверждает server-side prepare и локальную гонку discovery, но ещё не проверяет новое
  автоматическое ожидание. Реальный token и другие секреты в предоставленном JSONL отсутствовали.

В рабочем дереве client и Publisher helper больше не вызывают `Update-IscsiTarget` для ещё не
существующего объекта. Они обновляют точный portal через `Update-IscsiTargetPortal`, немедленно
проверяют ожидаемый IQN и при необходимости выполняют до 59 повторов с интервалом в одну
секунду. Client не создаёт session и не меняет Windows-диски при timeout; Publisher сохраняет
pending state и offline-диски.

### Локальные автоматические проверки

- PowerShell parser из `mcr.microsoft.com/powershell:7.5-ubuntu-24.04` — syntax passed для всех
  `.ps1`.
- Pester 5.7.1 в том же Linux PowerShell-контейнере — **63 passed, 0 failed, 1 skipped**.
  Покрыты немедленное обнаружение, появление target после нескольких refresh, посторонний IQN,
  временная ошибка portal, ровно 60 проверок/59 ожиданий, client timeout без connect/disk
  mutations, краткий JSONL и сохранение Publisher pending state. Пропущен только Windows ACL
  object test.
- `ruff check .` — passed.
- `pytest -q --cov=iscsi_reset_service --cov-report=term-missing` на Python 3.12.7 —
  **133 passed**, total coverage 79%.
- `docker compose config --quiet` — passed.
- `docker compose up --build --abort-on-container-exit --exit-code-from windows-simulation` —
  passed на локальном arm64 Docker host; оба сервиса сообщили version `0.4.4`, итог —
  `Interaction suite passed`. После проверки выполнен `docker compose down --volumes`.
- Локальный release-каталог содержит семь ожидаемых файлов. `sha256sum --check SHA256SUMS` и
  `docker compose -f <bundle> config --quiet` завершились успешно.

Физический первый запуск без зарегистрированного `MSFT_iSCSITarget`, включая автоматический
refresh client и Publisher, остаётся ожидающим проверки. Реализация выпускается как `v0.4.5`;
по команде оператора локальный gate перед tag повторно не запускался, итогом выпуска считается
только успешное завершение Python, Compose и Windows PowerShell 5.1 jobs в GitHub Actions.

## GitHub Release v0.4.4 — 2026-08-22

- Hotfix собран из commits `d72ee30` и `0aaef0e`; аннотированный tag `v0.4.4` указывает на
  `0aaef0e68a56819311e92e570d42cc95eefef93f`.
- Повторный branch CI run `32588611525` завершился success во всех jobs: Python/JavaScript,
  Compose interaction и Windows PowerShell 5.1. На Windows Pester 5.7.1 выполнил **55 passed,
  0 failed, 0 skipped** за 9.11 секунды.
- Tag publish run `32588787809` завершил validate, повторный полный verification и publish со
  статусом success; GitHub Release опубликован как
  `https://github.com/Xerz/iscsi-reset-service/releases/tag/v0.4.4`.
- Release содержит ровно семь ожидаемых assets: TrueNAS YAML, `image-digest.txt`,
  `SHA256SUMS` и четыре операторских `.ps1`. Скачанные заново файлы прошли
  `sha256sum --check SHA256SUMS`.
- Скачанный workflow artifact `iscsi-reset-service-v0.4.4-truenas` содержит те же семь файлов;
  каждый файл побайтно совпал с соответствующим GitHub Release asset, повторная checksum
  verification прошла.
- Bundle прошёл `docker compose config --quiet`, содержит два одинаковых image reference
  `ghcr.io/xerz/iscsi-reset-service@sha256:5da535dffc376222d6de1e0bebf818a151b79efbd6351a885c2ccdd0248219e7`,
  два management-IP placeholder и site-specific пути `/mnt/tank/...`.

Физическая перестановка автоматически назначенных букв на реальном Windows/TrueNAS стенде
после этого hotfix остаётся ожидающей проверки.

## Client installer и согласование drive letters v0.4.4 — 2026-08-22

Client installer больше не принимает raw token в аргументах и использует well-known SID для
ACL. Текущий рабочий набор дополнительно согласует автоматически назначенные Windows буквы
только внутри полного доказанного по NAA client-набора, ограниченно ждёт готовности
partition/volume metadata и пишет подробный локальный JSONL без token. Reset API, schema v3,
SQLite и параметры runtime-скрипта не изменялись.

### Операторские данные реальной Windows и TrueNAS

- Интерактивный installer из commit `879c28f` успешно завершился на русской Windows; скрытый
  token и IP были приняты, scheduled task создана. Точное содержимое итогового ACL отдельно не
  снималось.
- При отсутствии старых клонов первый запуск создал правильные ZFS clones, extent mappings и
  перевёл клиента `beast` на активный release в панели. После подключения Windows новая session
  отключалась на стадии локальной проверки дисков.
- Реальный `C:\ProgramData\IscsiReset\logs\reset.jsonl` четыре раза зафиксировал
  `disk_validation: Drive letter E: is occupied`. Отдельный `LOCAL_SESSION_ACTIVE` был
  намеренно вызван оператором и к дефекту не относится.
- Последующие подключения и переход на следующий release завершались; один диск визуально
  переподключался при автоматическом назначении букв. Проверка rollback реального клона также
  прошла: созданный клиентский файл исчез, чистый том подключился.

Это подтверждает server-side prepare/release/clone flow и локализованный installer, но ещё не
проверяет новое автоматическое согласование конфликтующих букв из текущего рабочего дерева.

### CI commit `879c28f`

- Python/JavaScript и Compose interaction jobs прошли.
- Windows PowerShell 5.1 job выполнил **34 tests successfully** и упал на одной новой ACL
  assertion: .NET возвращает `IdentityReference` как отображаемые имена
  `NT AUTHORITY\SYSTEM`/`BUILTIN\Administrators`, хотя правила были созданы из SID. Текущий
  тест переводит каждую identity обратно в `SecurityIdentifier` перед сравнением; production
  ACL-код не менялся.

### CI commit `d72ee30`

- Python/JavaScript и Compose interaction jobs прошли.
- Windows PowerShell 5.1 подтвердил исправление ACL assertion, но обнаружил вторую разницу
  тестовой среды: настоящий `Get-Partition` объявляет `DiskNumber` как `UInt32[]`, поэтому
  Pester передавал mock-функциям одноэлементный массив вместо scalar из Linux-заглушки.
- До выполнения letter logic успели пройти **45 tests**, а девять Windows reconciliation tests
  завершились одним и тем же test-only преобразованием `UInt32[]` в `Int32`; production-код в
  этих падениях не участвовал. Текущие mocks явно требуют ровно один disk number и извлекают
  его первый элемент.

### Локальные автоматические проверки текущего hotfix

- `ruff check .` — passed.
- `pytest -q --cov=iscsi_reset_service --cov-report=term-missing` — **133 passed**; release
  bundle regression по-прежнему покрывает все четыре операторских `.ps1`.
- `node --check src/iscsi_reset_service/static/app.js`,
  `node tests/static_connection_presentations.test.mjs` и `git diff --check` — passed.
- Все `.ps1` разобраны PowerShell parser из `mcr.microsoft.com/powershell:7.5-ubuntu-24.04` —
  syntax passed.
- Pester 5.7.1 в Linux PowerShell-контейнере — **54 passed, 1 skipped**. Проверены правильные,
  свободные и переставленные `E/F`, внешний владелец, wrong/extra NAA, read-only, лишние
  partitions, label mismatch, metadata retry/timeout, partial assignment, итоговая сверка,
  этапы JSONL и отсутствие token. Пропущен только настоящий Windows ACL object test.
- `docker compose config --quiet` — passed.
- `docker compose up --build --abort-on-container-exit --exit-code-from
  windows-simulation` — passed на локальном arm64 Docker host. Оба application containers
  сообщили version `0.4.4`; итог — `Interaction suite passed`. Затем выполнен
  `docker compose down --volumes`.

Windows PowerShell 5.1 CI и физическая перестановка автоматически назначенных букв остаются
ожидающими следующих отдельных шагов. Результат публикации tag и release assets фиксируется
отдельной записью после завершения release workflow.

## Один dual-role Publisher/client ПК v0.4.3 — 2026-08-22

В рабочем дереве schema v3 разрешает ровно одному client повторять полную пару
`publisher.source_ip + publisher.initiator_iqn` при обязательной отдельной target. Частичные
совпадения и второй shared client отклоняются. Контракты Reset API, SQLite и PowerShell не
изменялись. Изменения выпущены аннотированным tag `v0.4.3` из commit `c6b0f8b`.

### Локальные автоматические проверки v0.4.3

- `ruff check .` — passed.
- `pytest -q` на локальном Python 3.12 — **133 passed**. Покрыты schema, независимая проверка
  обеих target, неправильные и отсутствующие точные IQN/`/32`, сохранение config, блокировка
  client prepare при master session, блокировка stage/activation при client session, точная
  причина отказа activation и разрешение операций после отключения.
- `node --check src/iscsi_reset_service/static/app.js` и
  `node tests/static_connection_presentations.test.mjs` — passed. Ожидаемая активная вторая
  роль отображается предупреждением с target IQN, неизвестное частичное совпадение остаётся
  красным `identity conflict`.
- `docker compose config --quiet` и `git diff --check` — passed.
- `docker compose up --build --abort-on-container-exit --exit-code-from
  windows-simulation` — passed на локальном arm64 Docker host. Оба application containers
  сообщили version `0.4.3`; mock stage→activate и failpoint→retry client prepare завершились
  строкой `Interaction suite passed`. После проверки выполнен `docker compose down --volumes`.
- Локальная имитация выпуска содержит ровно семь файлов для `v0.4.3`.
  `sha256sum --check SHA256SUMS` завершился `OK` для YAML, digest-файла и четырёх `.ps1`, а
  сгенерированный YAML прошёл `docker compose config --quiet`.

- CI ветки `main` для commit `c6b0f8b` завершился успешно: Python/JavaScript, Compose interaction
  и Windows PowerShell 5.1/Pester прошли. Publish workflow для tag `v0.4.3` повторно выполнил
  тот же gate, собрал linux/amd64 image, создал provenance attestation и GitHub Release.
- Опубликованный GitHub Release `v0.4.3` скачан повторно. Он содержит ровно семь assets;
  `sha256sum --check SHA256SUMS` завершился `OK` для YAML, digest-файла и четырёх `.ps1`.
  Release YAML прошёл `docker compose config --quiet`, содержит два одинаковых image reference
  `ghcr.io/xerz/iscsi-reset-service@sha256:30f7ac8a891145bd728031b21f82f0d188ad3186e77aac013958a4b3ffc21e7e`,
  два placeholder управляющего IP-адреса и не содержит старых Admin API artifacts.

Фактическое переключение одного Windows ПК между master и client target, классификация реальных
сеансов TrueNAS и повторное разрешение stage/activation после полного отключения остаются
ожидающими физического стенда.

## Документация и комплект выпуска v0.4.2 — 2026-08-22

Эта ещё не опубликованная версия расширяет русскоязычный README и добавляет четыре
самостоятельных операторских PowerShell-файла в комплект GitHub Release. API, schema v3,
SQLite и рабочая логика сервисов не менялись. Исторические результаты v0.4.1 ниже сохраняются;
результаты новых проверок v0.4.2 добавлены отдельным списком.

### Проверки изменений v0.4.2

- `ruff check src tests` — passed.
- `pytest -q` на локальном Python 3.12 — **116 passed**.
- `node --check src/iscsi_reset_service/static/app.js`, `docker compose config --quiet` и
  `git diff --check` — passed.
- Три Mermaid-схемы из README отрендерены через `@mermaid-js/mermaid-cli` в SVG и PNG;
  синтаксис прошёл, подписи просмотрены визуально, пересекавшиеся подписи первой схемы
  упрощены.
- Локальная имитация каталога выпуска содержит ровно семь файлов: YAML, `image-digest.txt`,
  `SHA256SUMS` и четыре операторских `.ps1`. В Linux-контейнере
  `sha256sum --check SHA256SUMS` завершился `OK` для всех шести проверяемых файлов.
- Сгенерированный YAML прошёл `docker compose config --quiet` и содержит два одинаковых
  digest-pinned `image`.
- `docker compose up --build --abort-on-container-exit --exit-code-from windows-simulation` —
  passed на локальном arm64 Docker host: оба application containers сообщили version `0.4.2`,
  выполнены mock stage→activate и failpoint→retry client prepare, итог —
  `Interaction suite passed`. После прогона выполнен `docker compose down --volumes`.
- GitHub Actions для commit `66917b0` завершились успешно в двух workflow: Python, Compose и
  Windows PowerShell 5.1/Pester прошли как в `main`, так и перед публикацией tag `v0.4.2`.
- Опубликованный GitHub Release `v0.4.2` скачан повторно. Он содержит ровно семь assets;
  `sha256sum --check SHA256SUMS` завершился `OK` для YAML, digest-файла и всех четырёх `.ps1`.
  Release YAML прошёл `docker compose config --quiet`, содержит два одинаковых image reference
  `ghcr.io/xerz/iscsi-reset-service@sha256:2cfbb2807bebb91f8cb39524243d94028699a8b59ff653c4a35cbd2afc79ba7f`
  и два placeholder управляющего IP-адреса. Устаревшие Admin API artifacts отсутствуют.

### Исторические проверки v0.4.1

- `ruff check src tests` — passed.
- `pytest -q` на локальном Python 3.12 — **114 passed**.
- `node --check src/iscsi_reset_service/static/app.js` и `git diff --check` — passed.
- `docker compose config --quiet` — passed.
- `docker compose up --build --abort-on-container-exit --exit-code-from
  windows-simulation` — passed на локальном arm64 Docker host: два application containers
  сообщили version `0.4.1`, Management выполнил mock stage→activate до Publisher reconnect,
  Reset API прошёл fault→retry client prepare, suite завершился `Interaction suite passed`.
  После прогона выполнен `docker compose down --volumes`.
- Release renderer с тестовым immutable digest и последующий `docker compose -f <bundle>
  config --quiet` — passed. Bundle содержит ровно два одинаковых digest-pinned image reference,
  два management-IP API placeholder и не содержит `:8444`, admin TLS/client secrets или
  TrueNAS API URL на loopback.
- Все PowerShell tests выполнены в pinned Linux PowerShell image с Pester 6.1.0 — **19 passed**.
  Это дополнительная проверка syntax/logic, не Windows PowerShell 5.1.
- В in-app browser на локальном mock runtime пройдены management login, все шесть разделов,
  form↔YAML, одноразовый client token с очисткой raw value после dialog, config save, restart
  banner и блокировка release action до restart. Desktop и viewport `390×844` проверены
  визуально; frontend console не содержала warnings/errors.

Исторические результаты v0.3.x не считаются проверкой архитектуры v0.4.x.

### Операторские данные реального TrueNAS 25.10

Оператор подтвердил на физическом TrueNAS:

- `pool.dataset.query` должен запрашивать `properties: ["keystatus"]`; тогда master zvol и
  filesystem clone parents возвращают вычисленное `locked: false`. Значения `true` и `null`
  по-прежнему исключаются fail-closed.
- `SSDGames/MainGames`, `Sas/Games-Device/Older-Games/oldergames`,
  `SSDGames/clients/{chimera,beast}` и `Sas/clients/{chimera,beast}` были подтверждены как
  unlocked объекты ожидаемых типов.
- TrueNAS middleware не разрешил добавить `127.0.0.1` в `ui_address`, а соединение контейнера к
  `wss://127.0.0.1/api/current` отклонялось. Из контейнера нужен назначенный машине management
  IP TrueNAS; Publisher NAT/VIP для этого не используется.
- На Management UI v0.4.0 базовый discovery начал работать с обновлённым token/key, но live
  dashboard возвращал dependency 503 до выдачи discovery user роли `SNAPSHOT_READ`. После
  добавления роли live state заработал. Это подтверждает, что `SNAPSHOT_READ` входит в
  обязательный read-only набор для проверки release snapshots и `@clean`.
- Реальный `iscsi.target.query` возвращает `auth_networks` на верхнем уровне target, отдельно
  от `groups`. Ответ target `master` содержал `auth_networks: ["10.20.40.20/32"]`, тогда как
  v0.4.0 ошибочно искал это поле внутри каждого group и поэтому fail-closed сообщал ложный
  `publisher target does not authorize the exact source IP /32`. Hotfix v0.4.1 читает
  фактическую форму TrueNAS 25.10; patched image ещё требует повторной проверки на стенде.

Эти данные подтверждают discovery prerequisites, но не проверяют новый management release
workflow.

### Обязательно ожидает физического TrueNAS/Windows стенда

- Полный least-privilege набор read-only discovery key и отдельного mutation service key на
  фактическом patch release TrueNAS SCALE 25.10; необходимость `SNAPSHOT_READ` для discovery
  user уже подтверждена оператором.
- Два production containers, реальные directory mounts, POSIX lock/history/fsync и доступ к
  Management UI только через SSH tunnel.
- Реальная классификация Publisher/client iSCSI sessions, включая partial identity conflict.
- Dual-role Windows ПК: взаимоисключающее подключение master/client target, понятные role
  warnings и fail-closed блокировка prepare/stage/activation до полного отключения другой роли.
- Dashboard mapping по extent path, managed ZFS properties, origin snapshot и `@clean`.
- Publisher helper `Disconnect`/`Reconnect` на Windows PowerShell 5.1: exact NAA, offline,
  pending recovery, непостоянная session и безопасный online.
- Stage/activation при отключённом Publisher, activation до reconnect, отказ при неожиданном
  reconnect и reconciliation incomplete release с исходным request ID.
- Корректность snapshot existence, clone dependencies и строгого отчёта «кандидат для ручной
  очистки» на реальном storage. Автоматическое удаление не реализовано и не разрешено.
- Реальный Reset API TLS, Windows client prepare/reset, NTFS и сохранность NAA/serial/LUN.

До выполнения этих пунктов нельзя объявлять физический TrueNAS/Windows flow пройденным. Порядок
и ограничения destructive-проверок приведены в `TEST-PLAN.md`.
