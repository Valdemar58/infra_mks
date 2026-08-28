# infra

Инфраструктурные конфиги, намеренно отделенные от `docker-compose.yml`/`docker-compose.dev.yml` самого приложения - жизненный цикл инфры не должен зависеть от деплоя приложения (и наоборот). Временное расположение внутри этого репозитория до объединения с остальными infra-конфигами и выноса в отдельный репозиторий.

## observability

Loki + Grafana Alloy + Grafana: сохраняет JSON stdout-логи приложения (собственный драйвер Docker `json-file` теряет их при пересборке контейнера) и делает их доступными для поиска. Alloy обнаруживает контейнеры `asu_toir_*` через Docker socket и отправляет их логи в Loki; в Grafana уже настроен источник данных Loki.

**Запуск** (независимо от compose-файлов самого приложения):
```
cd infra/observability
cp .env.example .env   # задать GF_SECURITY_ADMIN_PASSWORD
docker compose up -d
```
Grafana: http://localhost:3001 (логин `admin` / `GF_SECURITY_ADMIN_PASSWORD`). Поиск по логам через LogQL, например `{container="asu_toir_api"} | json | username="ivanov"`.

**Значения конфигурации:**
| Параметр | Значение | Где |
|---|---|---|
| Хранение логов | 90 дней (`2160h`) | `loki-config.yml` → `limits_config.retention_period` |
| Порт Loki | `3100` (только внутри сети, наружу не пробрасывается) | `loki-config.yml` → `server.http_listen_port` |
| Порт Grafana | `3001` → контейнер `3000` | `docker-compose.yml` |
| Хранилище | filesystem, именованные volume'ы `loki-data`/`grafana-data` | `docker-compose.yml` |
| Область сбора | только имена, подходящие под `asu_toir.*` | `alloy-config.alloy` |

**Дашборд:** при первом запуске в Grafana уже есть дашборд "АСУ ТОиР - Активность" (`grafana/provisioning/dashboards/activity.json`) - запросы к API во времени и по статусам, ошибки, топ пользователей и эндпоинтов, просмотры страниц по пользователям/страницам.

**Как перенести правки дашборда из UI обратно в репозиторий:** `allowUiUpdates: true` (`grafana/provisioning/dashboards/dashboards.yml`) разрешает редактировать и сохранять дашборд прямо в Grafana, но эти изменения остаются только в `grafana-data` (volume) - файл `activity.json` в репозитории сам по себе не обновляется. Чтобы зафиксировать правки:
1. Открыть дашборд → значок настроек (шестеренка) → **JSON Model** (либо Share → Export → **Save dashboard JSON to file**).
2. Скопировать/сохранить JSON поверх `infra/observability/grafana/provisioning/dashboards/activity.json`.
3. Убрать/проверить поля `"id"` (не должно быть - иначе Grafana попытается сослаться на числовой id конкретной инсталляции) и `"version"` (провижининг сам проставит), оставить `"uid": "asu-toir-activity"` без изменений - на него ссылаются другие места.
4. Закоммитить файл. Через `updateIntervalSeconds: 30` (или после `docker compose restart grafana`) обновленный файл снова подхватится как источник правды.

## nginx

Reverse-proxy, переиспользуемый для любых сервисов, а не только Keycloak: конфиги проксируемых сервисов кладутся отдельными файлами в `conf.d/`, сам nginx не меняется. Подключен к внешней сети `app-network` (та же сеть, что уже связывает `api`/`streamlit` самого приложения - отдельной сети для инфры не заводим, чтобы не дублировать одну и ту же роль "достучаться до контейнера из другого compose-проекта" двумя сетями), чтобы доставать сервисы из других compose-проектов.

**Запуск:**
```
docker network create app-network   # один раз, если еще не создана
cd infra/nginx
docker compose up -d
```
Добавить новый проксируемый сервис: положить `conf.d/<service>.conf`, подключить этот сервис к сети `app-network`, перечитать конфиг:
```
docker compose exec nginx nginx -s reload
```

**Значения конфигурации:**
| Параметр | Значение | Где |
|---|---|---|
| Порты | `80`/`443` | `docker-compose.yml` |
| Сеть | внешняя `app-network`, создается вручную один раз | `docker-compose.yml` |
| Сертификаты | из `infra/certs/` (см. ниже) | `conf.d/keycloak.conf` |
| Конфиги проксируемых сервисов | по одному файлу на сервис в `conf.d/` | `conf.d/*.conf` |

**Уже подключенные сервисы:**
| Хост | Куда проксирует | Файл |
|---|---|---|
| `appsrvs.auth` | keycloak:8080 | `conf.d/keycloak.conf` |
| `appsrvs.registry` | registry_ui:80 | `conf.d/docker_registry.conf` |
| `appsrvs` | сам asu_toir (streamlit) | `conf.d/asu_toir.conf` |

`asu_toir.conf` проксирует само приложение (не только инфру) - поэтому `streamlit` в корневых `docker-compose.yml`/`docker-compose.dev.yml` подключен к той же `app-network`, которую использует и nginx. Содержит апгрейд до WebSocket (`proxy_set_header Upgrade`/`Connection "upgrade"`) - без этого Streamlit загружается, но не реагирует на ввод (использует WS для рефреша интерфейса). Имя контейнера в upstream различается dev/прод (`asu_toir_dev` / `asu_toir`) - см. комментарий в файле.

## keycloak

Прод: только Keycloak, БД - внешний Postgres-сервер (не dockerized). Dev: Keycloak + одноразовый dockerized Postgres, без LDAP - вместо AD локальный пользователь `admin_dev`, тот же username, что и dev-заглушка на стороне приложения.

**Прод-запуск** (БД `keycloak` и пользователь должны быть заранее созданы на внешнем сервере вручную; сеть `app-network` - см. `## nginx`):
```
cd infra/keycloak
cp .env.example .env   # задать KC_DB_URL/USERNAME/PASSWORD, KC_BOOTSTRAP_ADMIN_*
docker compose up -d
```
После первого импорта задать реальные секреты (правка `realm-export.json` не действует на уже поднятый realm - `--import-realm` игнорирует существующий realm):
```
docker exec -it keycloak kcadm.sh config credentials --server http://localhost:8080 --realm master --user $KC_BOOTSTRAP_ADMIN_USERNAME --password $KC_BOOTSTRAP_ADMIN_PASSWORD
docker exec -it keycloak kcadm.sh get components -r master -q type=org.keycloak.storage.UserStorageProvider   # найти id LDAP-компонента
docker exec -it keycloak kcadm.sh update components/<id> -r master -s 'config.bindCredential=["<реальный-пароль>"]'
docker exec -it keycloak kcadm.sh update clients/<streamlit-client-id> -r master -s secret=<значение, совпадающее с CLIENT_STREAMLIT_SECRET приложения>
```

**Dev-запуск** (самодостаточен, не требует ни `infra/nginx`, ни внешнего Postgres):
```
cd infra/keycloak
docker compose -f docker-compose.dev.yml up -d
```
Keycloak: http://localhost:8080, логин `admin_dev`/`admin_dev` для проверки реального OIDC-флоу приложения.

**Значения конфигурации:**
| Параметр | Значение | Где |
|---|---|---|
| БД (прод) | внешний Postgres, создается вручную заранее | `.env` → `KC_DB_URL`/`KC_DB_USERNAME`/`KC_DB_PASSWORD` |
| БД (dev) | dockerized, одноразовая | `docker-compose.dev.yml` |
| Admin (прод) | `KC_BOOTSTRAP_ADMIN_USERNAME`/`_PASSWORD` | `.env` |
| Admin (dev) | `admin`/`admin` | `docker-compose.dev.yml` |
| LDAP bind credential | плейсхолдер в файле, реальное значение - через `kcadm.sh` после импорта | `realm-export.json` |
| Dev-пользователь | `admin_dev`/`admin_dev`, без LDAP | `realm-export.dev.json` |
| Хостнейм | `appsrvs.auth` | `.env` → `KC_HOSTNAME` |

**Бэкап:**

Дамп внешней БД:
```
pg_dump -h <db-host> -U keycloak -d keycloak -F c -f keycloak_db_$(date +%Y%m%d).dump
# восстановление: pg_restore -h <db-host> -U keycloak -d keycloak --clean --if-exists keycloak_db_YYYYMMDD.dump
```

Полный офлайн-экспорт realm'а (с секретами/ключами, ловит правки, сделанные через admin-консоль после последнего коммита; требует краткой остановки):
```
docker compose -f infra/keycloak/docker-compose.yml stop keycloak
docker compose -f infra/keycloak/docker-compose.yml run --rm --entrypoint "" keycloak \
  /opt/keycloak/bin/kc.sh export --dir /opt/keycloak/data/backup --realm master --users skip
docker compose -f infra/keycloak/docker-compose.yml start keycloak
```
`--users skip` - чтобы не затягивать в каждый бэкап кэш пользователей из LDAP.

Быстрая проверка расхождений конфигурации без остановки (без секретов и пользователей - не замена дампа выше):
```
curl -s -X POST "https://<keycloak-host>/admin/realms/master/partial-export?exportClients=true&exportGroupsAndRoles=true" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -o realm-live-snapshot.json
diff <(jq -S . infra/keycloak/realm-export.json) <(jq -S . realm-live-snapshot.json)
```

## docker_registry

Приватный Docker-registry (`registry:3.1.1`) + веб-UI (`joxit/docker-registry-ui`), с аутентификацией и без dockerized-состояния, теряющегося при пересборке. UI сам проксирует `/v2/*` на registry по внутренней сети - наружу (через `infra/nginx`) виден только UI, один origin, без CORS.

**Запуск:**
```
mkdir -p infra/docker_registry/auth
docker run --rm --entrypoint htpasswd httpd:2 -Bbn <user> '<password>' > infra/docker_registry/auth/htpasswd
cd infra/docker_registry
docker compose up -d
```
После этого (и после того, как `docker network create app-network` и `infra/nginx` подняты) registry доступен по `https://appsrvs.registry/` - UI в браузере, `docker login/push/pull appsrvs.registry/...` по тому же адресу.

**Значения конфигурации:**
| Параметр | Значение | Где |
|---|---|---|
| Хост | `appsrvs.registry` | `infra/nginx/conf.d/docker_registry.conf` |
| Аутентификация | htpasswd (bcrypt), обязательна на push/pull | `config.yml` → `auth.htpasswd` |
| Healthcheck | отдельный debug-listener без авторизации | `config.yml` → `http.debug.addr`, `:5001/debug/health` |
| Хранилище | filesystem, именованный volume `registry_data` | `docker-compose.yml` |
| Delete API | включен (нужен для GC) | `config.yml` → `storage.delete.enabled` |

**Garbage collection** (сначала `--dry-run`, проверить вывод, потом реальный запуск - GC читает только `config.yml`, переменные окружения `REGISTRY_*` не учитывает):
```
docker compose -f infra/docker_registry/docker-compose.yml exec registry \
  bin/registry garbage-collect --dry-run /etc/distribution/config.yml
docker compose -f infra/docker_registry/docker-compose.yml exec registry \
  bin/registry garbage-collect /etc/distribution/config.yml
```

**Бэкап** (файловое хранилище, не БД - обычный tar volume'а):
```
docker run --rm -v docker_registry_registry_data:/data -v $(pwd):/backup alpine \
  tar czf /backup/registry_data_$(date +%Y%m%d).tar.gz -C /data .
```

## valhalla

Self-hosted движок маршрутизации для АСУ ТОиР: матрицы расстояний и геометрия маршрутов вместо внешнего OpenRouteService, координаты точек не покидают сеть предприятия. Приложение переключается между движками переменной `ROUTE_ENGINE=ors|valhalla` в корневом `.env` и без этого модуля полноценно работает на `ors`.

Модуль самодостаточен и предназначен к выносу в отдельный репозиторий на отдельный сервер: общих томов и импортов с приложением у него нет, обмен только по HTTP. Установка, сборка тайлов, обязательный патч `valhalla.json`, публикация кастомных дорог и обновление базовой карты описаны в [valhalla/README.md](valhalla/README.md).

Что нужно знать со стороны приложения:

- Адреса задаются переменными `VALHALLA_URL` и `VALHALLA_URL_WINTER` и указывают на сетевые алиасы `valhalla-summer` и `valhalla-winter` в `app-network`. Поскольку сервис живет на другом сервере, `app-network` должна быть overlay-сетью swarm: `docker network create -d overlay --attachable app-network`.
- Публикацию кастомных дорог выполняет `publisher` на стороне Valhalla. Приложение только ведет очередь заявок (`/v1/custom-roads/publish-requests`) и отдает дороги; файловых шагов и доступа к каталогу тайлов у него нет. Publisher ходит в API с M2M токеном, роль должна иметь права `custom_roads` view и edit.
- Логи контейнеров Valhalla собирает Alloy на своем хосте, а не тот, что описан выше в `## observability`: он читает локальный Docker socket и видит только контейнеры своей машины.

## certs

Общее хранилище сертификатов для всех сервисов, которым нужен TLS (сейчас - nginx). Реальные ключи/сертификаты (`*.key`/`*.pem`, в т.ч. внутри `ca/`) в `.gitignore` - в git попадает только `ca/ca.cnf` (конфиг генерации, без секретов).

```
infra/certs/
├── fullchain.pem   # серверный сертификат (только leaf - см. ниже, почему не chain+root)
├── server.key      # приватный ключ сервера
└── ca/
    ├── ca.cnf        # конфиг для генерации (в git)
    ├── rootCA.key    # приватный ключ CA - хранить отдельно от сервера, не в docker volume
    └── rootCA.pem    # публичный сертификат CA - раздается клиентам/антивирусу для доверия
```

| Файл | Назначение |
|---|---|
| `fullchain.pem` | серверный сертификат (`ssl_certificate`) |
| `server.key` | приватный ключ сервера (`ssl_certificate_key`) |
| `ca/rootCA.pem` | корневой сертификат CA - импортируется в доверенные хранилища клиентов |
| `ca/rootCA.key` | приватный ключ CA - им подписываются серверные сертификаты, критичен |

### Как правильно сгенерировать (self-signed внутренний CA + серверный сертификат)

**Важно: `fullchain.pem` должен содержать только сам серверный (leaf) сертификат, без корневого CA.** Раздача корневого сертификата сервером ломает строгую проверку цепочки у части клиентов (получена ошибка `unable to get local issuer certificate` у Python `ssl`, `curl --cacert` и `openssl verify` при попытке отдавать leaf+root вместе) - корень клиент должен получить один раз отдельно и доверять ему сам, а не получать его каждый раз от сервера.

**При генерации через `openssl req -x509 -addext ...`:** системный `openssl.cnf` уже применяет `x509_extensions = v3_ca` по умолчанию для `-x509`-сертификатов, который сам добавляет `basicConstraints`. Дублирующий `-addext "basicConstraints=..."` поверх него создает **два** расширения `basicConstraints` в одном сертификате - формально невалидный X.509, который строгие валидаторы (`cryptography`, Python `ssl`) отвергают, а некоторые (`curl`, `openssl verify`) молча трактуют как "не могу проверить цепочку" вместо явной ошибки. Поэтому ниже - генерация через явный конфиг (`ca.cnf`), без `-addext`, с полным контролем расширений вместо использования недетерминированных значений по умолчанию.

```
cd infra/certs

# 1. Ключ и самоподписанный корневой сертификат CA (10 лет)
openssl genrsa -out ca/rootCA.key 4096
openssl req -x509 -new -nodes -key ca/rootCA.key -sha256 -days 3650 \
  -out ca/rootCA.pem -config ca/ca.cnf -extensions v3_ca

# 2. Ключ и запрос на серверный сертификат (CN и SAN должны совпадать - CN тут не
#    используется современными клиентами для проверки хоста, важен только SAN)
openssl genrsa -out server.key 2048
openssl req -new -key server.key -out ca/server.csr \
  -subj "/CN=appsrvs.registry/O=asu_toir"

# 3. Подпись серверного сертификата корневым CA (3 года), SAN - из ca.cnf [leaf_ext]
openssl x509 -req -in ca/server.csr -CA ca/rootCA.pem -CAkey ca/rootCA.key \
  -CAcreateserial -out fullchain.pem -days 1095 -sha256 \
  -extfile ca/ca.cnf -extensions leaf_ext
rm ca/server.csr ca/rootCA.srl
```
`ca.cnf`'s `[leaf_ext]` содержит `subjectAltName` - при добавлении нового хоста/IP (или очередной генерации под новый сервис) достаточно обновить список там и пересобрать шаги 2-3, CA (шаг 1) переделывать не нужно.

### Доверие в Windows + Kaspersky Endpoint Security

Раздать серверный сертификат (`fullchain.pem`) недостаточно - клиенты должны **доверять `ca/rootCA.pem`** (это самоподписанный внутренний CA, публично никем не подписан). Два независимых места, куда его нужно добавить:

1. **Хранилище Windows** (Trusted Root Certification Authorities) - через `certutil -addstore -f "Root" rootCA.pem` (от администратора) или импортом через `certmgr.msc`. Этого обычно достаточно для большинства TLS-клиентов (включая Docker daemon на Windows, использующий системное хранилище).
2. **Kaspersky Endpoint Security - отдельно, если включено сканирование зашифрованных соединений.** KES перехватывает TLS-трафик и переподписывает его собственным сертификатом ("Kaspersky Anti-Virus personal root certificate"), но перед этим **сам проверяет цепочку исходного (нашего) сертификата** - и ведет для этого **свой собственный** список доверенных корневых сертификатов, отдельный от системного хранилища Windows. Без добавления `rootCA.pem` туда же KES может считать соединение с `appsrvs.registry` недоверенным (ошибка/предупреждение "Certificate verification problem detected" независимо от того, что Windows уже доверяет сертификату).
   - **Локально**: настройки KES → General settings → Network settings → блок "Encrypted connections scan" → **Show certificates** → **Manage trusted root certificates** → Add → выбрать `rootCA.pem` (поддерживаются PEM/DER/CRT).
   - **Централизованно через Kaspersky Security Center** (правильный способ для организации, а не для одной машины): в политике KES → Application settings → General settings → Network settings → **Manage trusted root certificates** → Add - применится сразу на все машины под этой политикой.

Источники: [Configuring the encrypted connections scan settings](https://support.kaspersky.com/KESWin/11.1.0/en-US/175149.htm), [Installing trusted root certificates](https://support.kaspersky.com/help/KESWin/12.8/en-US/230925.htm).

Эта локально сгенерированная CA - рабочий вариант и для реального использования, и просто для тестирования до получения переподписанного корпоративного сертификата (см. `## docker_registry`/`## keycloak` - оба ожидают, что `appsrvs.registry`/`appsrvs.auth` там будут явно перечислены в SAN).
