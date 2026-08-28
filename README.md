# infra_mks

Инфраструктура для приложения АСУ: reverse-proxy с TLS, Keycloak, docker registry, сбор логов, маршрутизация Valhalla. Отдельный репозиторий с собственным жизненным циклом: деплой приложения и деплой инфраструктуры не зависят друг от друга. Все настраивается скриптами и `.env`, ставится на один сервер или на несколько, работает в проде без доступа к GitHub.

## Адреса

Все сервисы и само приложение доступны только по HTTPS через nginx. Имена задаются в корневом `.env` (`HOST_*`), по умолчанию:

| Адрес | Что | Куда проксируется |
|---|---|---|
| `https://appsrvs` | приложение, web-интерфейс | `APP_UI_UPSTREAM:8501` |
| `https://appsrvs.api` | приложение, API для внешних систем и M2M-токенов | `APP_API_UPSTREAM:8000` |
| `https://appsrvs.auth` | Keycloak | `keycloak:8080` |
| `https://appsrvs.registry` | docker registry, UI и `docker login/push/pull` | `registry_ui:80` |
| `https://appsrvs.grafana` | Grafana, логи | `grafana:3000` |
| `https://appsrvs.route/summer/`, `/winter/` | Valhalla, летний и зимний сезон | `valhalla-summer:8002`, `valhalla-winter:8002` |

Внутри `app-network` приложение ходит к сервисам напрямую по алиасам (`keycloak`, `valhalla-summer`, `valhalla-winter`, `loki`), nginx для него не обязателен.

## Быстрый старт

```
cp .env.example .env      # проверить SERVER_IP, имена HOST_*, APP_*_UPSTREAM
./setup.sh
```

Скрипт создает сеть, сертификаты и поднимает стеки по порядку: certs, nginx, keycloak, docker_registry, observability, valhalla. На первом запуске он остановится там, где нужны данные от вас (`.env` стека с паролями), скажет, что заполнить, и продолжит при повторном запуске. Повторный запуск безопасен: каждый шаг сам определяет, что уже сделано.

```
./setup.sh --only valhalla        # один стек (флаг повторяемый)
./setup.sh --skip valhalla        # все, кроме
./setup.sh --dev                  # keycloak в dev-режиме: свой postgres, без LDAP
./setup.sh --wait                 # valhalla: дождаться первой сборки тайлов
./setup.sh --agent                # observability: только Alloy на хосте без основного стека
./setup.sh --renew-certs          # перевыпустить серверный сертификат
```

В конце скрипт проверяет каждый адрес через nginx и печатает записи для DNS или hosts клиентов.

Ручные операции с любым стеком через `compose.sh`: он подставляет корневой `.env` и `.env` стека, чтобы действовали `IMAGE_MIRROR` и прочие общие настройки.

```
./compose.sh valhalla logs -f valhalla-summer
./compose.sh keycloak --dev down
./compose.sh nginx up -d --force-recreate
```

## Структура

```
.env.example        общие настройки: сеть, имена сервисов, приложение, сертификаты, зеркало образов
setup.sh            сборка всего по порядку
hosts.sh            проверка и настройка записей hosts на этой машине
compose.sh          docker compose стека с общими настройками
lib.sh              функции для скриптов стеков
offline/            зеркало и бандл образов для сервера без интернета
certs/              корневой CA и серверный сертификат
nginx/              reverse-proxy, шаблоны конфигов в templates/
keycloak/           OIDC, realm и тема входа
docker_registry/    приватный registry с UI
observability/      Loki, Alloy, Grafana
valhalla/           маршрутизация, свой README.md
```

У каждого стека: `docker-compose.yml`, `.env.example`, `setup.sh`. Стеки это отдельные compose-проекты, их можно поднимать и обновлять независимо.

## Сеть

Все стеки и приложение связывает внешняя docker-сеть `app-network`, ее создает `setup.sh` по `NETWORK_DRIVER` из `.env`.

**Один сервер** (`NETWORK_DRIVER=bridge`): обычная bridge-сеть, ничего настраивать не нужно.

**Несколько серверов** (`NETWORK_DRIVER=overlay`), например приложение на сервере 1, инфраструктура на сервере 2, Valhalla на сервере 3. Серверы объединяются в docker swarm, сеть становится overlay и attachable, все стеки по-прежнему поднимаются обычным `docker compose` (не `docker stack`: Valhalla нужны `container_name`, профили и bind mount). Имена и алиасы контейнеров резолвятся между хостами, поэтому nginx на сервере 2 находит `asu_toir` на сервере 1 и `valhalla-summer` на сервере 3 без дополнительной настройки.

1. Сервер инфраструктуры становится manager: `docker swarm init --advertise-addr <ip сервера 2>`.
2. Остальные серверы: `docker swarm join --token <токен> <ip сервера 2>:2377` (токен: `docker swarm join-token worker` на manager).
3. Между серверами открыты порты 2377/tcp (управление), 7946/tcp и udp (обмен состоянием), 4789/udp (VXLAN трафик сети). При MTU меньше 1500 на канале между серверами overlay-сети нужен `--opt com.docker.network.driver.mtu`.
4. На каждом сервере `NETWORK_DRIVER=overlay` в `.env`. На manager `setup.sh` создает сеть, на worker подключается к ней (Docker Compose начиная с 2.2 подключает контейнер к overlay-сети, которой еще нет локально; скрипт дополнительно проверяет доступность).
5. Запуск по серверам: сервер 2 `./setup.sh --skip valhalla`, сервер 3 `./setup.sh --only valhalla`, на сервере 1 поднимается приложение (см. «Приложение»). Логи с серверов 1 и 3 собирает Alloy-агент: `./setup.sh --only observability --agent`.

## Сертификаты

`certs/setup.sh` ведет весь цикл: создает корневой CA один раз, выпускает и продлевает серверный сертификат, проверяет состояние. Имена для сертификата берутся из `HOST_*` и `SERVER_IP` корневого `.env`.

```
./certs/setup.sh              сделать то, чего не хватает
./certs/setup.sh --check      отчет: сроки, SAN, соответствие ключа; код 1 при замечаниях, удобно для cron
./certs/setup.sh --renew      перевыпустить серверный сертификат
```

Добавление имени сервиса (новый `HOST_*`) требует только перевыпуска серверного сертификата: SAN живет в нем, а корень не меняется, поэтому клиентам ничего заново раздавать не нужно. `setup.sh` замечает недостающие имена и перевыпускает сертификат сам, nginx перечитывает его без перезапуска.

Что генерируется и почему это принимают строгие клиенты, в том числе Kaspersky Endpoint Security при проверке защищенных соединений (цепочка до доверенного корня, каждый подписывающий сертификат это CA, сроки действуют, имя совпадает с хостом, назначение это проверка подлинности сервера, структура и подпись корректны):

- Корень: RSA 4096, SHA-256, `basicConstraints=critical,CA:true`, `keyUsage=critical,keyCertSign,cRLSign`, идентификаторы ключа, срок `CERT_CA_DAYS` (10 лет). Рядом лежит DER-копия `rootCA.crt` для импорта в Windows и KES.
- Серверный: RSA 2048, SHA-256, `CA:false`, `keyUsage=digitalSignature,keyEncipherment`, `extendedKeyUsage=serverAuth`, идентификаторы ключа, SAN со всеми именами и IP, срок `CERT_LEAF_DAYS` (825 дней, предел для строгих клиентов).
- Расширения задаются только через секции конфига, без `-addext`: дублирование `basicConstraints` дает формально невалидный сертификат, который строгие валидаторы отвергают.
- `fullchain.pem` содержит только серверный сертификат. Корень в нем ломает проверку цепочки у части клиентов (`unable to get local issuer certificate` у Python, curl, openssl), клиент должен доверять корню сам.

Куда раздать корень (`certs/ca/rootCA.crt`):

- Windows: `certutil -addstore -f Root rootCA.crt` от администратора или через `certmgr.msc`.
- Kaspersky Endpoint Security ведет свой список доверенных корней отдельно от Windows. Локально: Настройки, Общие настройки, Сетевые настройки, блок «Проверка защищенных соединений», «Показать сертификаты», «Доверенные корневые сертификаты», «Добавить» (PEM, DER, CRT). Централизованно: политика KES в Kaspersky Security Center, тот же раздел. Без этого KES считает соединение недоверенным, даже если Windows корню уже доверяет.
- Docker на серверах, которые делают pull из registry: `/etc/docker/certs.d/<HOST_REGISTRY>/ca.crt` с содержимым `rootCA.pem`.
- CI runner и приложение: корень добавляется в их CA-бандл (у приложения `HOST_CUSTOM_CA_PATH`, объединенный бандл системных и нашего корня).

Свой корпоративный сертификат вместо самоподписанного: положить `fullchain.pem` (только серверный сертификат) и `server.key` в `certs/` без каталога `ca/`, скрипт только проверит их.

Замена корня (`--init-ca --force`) требует подтверждения и означает раздачу нового корня всем клиентам заново.

## DNS и hosts у клиентов

Все имена из `HOST_*` должны указывать на `SERVER_IP` сервера с nginx: записи во внутреннем DNS или строка в hosts (`C:\Windows\System32\drivers\etc\hosts`, `/etc/hosts`). Приложение находит Keycloak через `extra_hosts` в своем compose.

`hosts.sh` проверяет это на текущей машине и настраивает hosts, где DNS нет. Сначала каждое имя резолвится системным резолвером (hosts и DNS вместе), поэтому на машинах с внутренним DNS файл не трогается. Если имена не ведут на нужный IP, скрипт предлагает записать строку `IP имя1 имя2 ...` (Linux через `sudo`, Windows через окно UAC), заменяя строки с этими именами, и перепроверяет. `setup.sh` запускает эту проверку в конце (`--skip hosts` отключает).

```
./hosts.sh              проверить и предложить записать
./hosts.sh --check      только проверка, код 1 при расхождении
./hosts.sh --write      записать без вопросов
./hosts.sh --manual     показать строку для ручной правки и перепроверять по Enter
```

IP для записей берется из `HOSTS_IP` (`.env`), по умолчанию `SERVER_IP`. На машине, где nginx работает локально (dev), `HOSTS_IP=127.0.0.1`. Скрипт годится и для рабочих станций под Git Bash: достаточно клона репозитория и `.env` с именами.

## Прод без доступа к GitHub

В проде недоступны `raw.githubusercontent.com` и, как следствие, образы из `ghcr.io` (их слои раздаются с того же домена). Docker Hub, quay.io, PyPI и Geofabrik доступны. Что от этого зависит и как закрыто:

| Что | Откуда | Решение |
|---|---|---|
| `default_speeds.json`: образ Valhalla качает его при первой сборке тайлов, при ошибке падает | raw.githubusercontent.com | лежит в `valhalla/assets/`, `valhalla/setup.sh` кладет в каталог каждого сезона, publisher копирует в staging |
| `ghcr.io/valhalla/valhalla-scripted` | ghcr.io | зеркало `IMAGE_MIRROR` или бандл |
| `uv` для образа publisher | ghcr.io | ставится из PyPI в `Dockerfile.publisher` |
| образ publisher (сборка: Docker Hub, apt, PyPI) | | собирается на машине с интернетом, попадает в зеркало или бандл |
| nginx, Keycloak, registry, Loki, Alloy, Grafana | Docker Hub, quay.io | доступны напрямую, для единообразия тоже зеркалируются |
| PBF-карты | download.geofabrik.de | доступны; бандл может нести карту и готовые тайлы |

Все образы в compose-файлах записаны как `${IMAGE_MIRROR:-}<исходное имя>`. Пустой `IMAGE_MIRROR` означает исходные registry, `IMAGE_MIRROR=appsrvs.registry/mirror/` означает наш registry: образ `ghcr.io/valhalla/valhalla-scripted:3.8.3` превращается в `appsrvs.registry/mirror/ghcr.io/valhalla/valhalla-scripted:3.8.3`.

**Зеркало** (registry уже поднят). На машине с интернетом, после `docker login appsrvs.registry`:

```
./offline/list-images.sh              # список образов, берется из compose-файлов
./offline/mirror.sh --only-blocked    # ghcr.io и publisher; без флага все образы
```

На серверах `IMAGE_MIRROR=appsrvs.registry/mirror/` в `.env` и `docker login appsrvs.registry` на каждом хосте (на сервере Valhalla он нужен и publisher'у: builder-контейнер берет образ из зеркала). Обновление образа: поменять тег в compose, повторить `mirror.sh`, на сервере `./compose.sh <стек> pull` и `up -d`.

**Бандл** (сервер вовсе без сети или registry еще нет). На машине с интернетом:

```
./offline/bundle.sh                        # образы и default_speeds.json в offline/bundle/
./offline/bundle.sh --with-map --with-tiles # плюс карта и готовый летний тайлсет (~15 ГБ), без часа сборки на сервере
```

Каталог переносится на сервер, там:

```
./offline/load.sh <каталог>     # проверка контрольных сумм, docker load, раскладка файлов
OFFLINE=1 в .env                # setup.sh ничего не скачивает и не собирает, только проверяет наличие образов
./setup.sh
```

Проверка, что репозиторий ничего не тянет с GitHub: `grep -rE 'githubusercontent|ghcr\.io' .` должен находить только строки `image:` с префиксом `${IMAGE_MIRROR:-}`, `VALHALLA_IMAGE` и `valhalla/assets/README.md`.

## Стеки

### nginx

Конфиги лежат в `nginx/templates/*.conf.template` и рендерятся образом nginx при старте контейнера: подставляются переменные `HOST_*`, `APP_*` и `SERVER_IP` из корневого `.env` (`NGINX_ENVSUBST_FILTER`), собственные переменные nginx не трогаются. Общие куски в `nginx/snippets/`: TLS и резолвер, заголовки безопасности, заголовки проксирования, WebSocket. Upstream резолвятся в момент запроса, поэтому nginx поднимается раньше сервисов и переживает их перезапуск.

После правки шаблонов или `.env` контейнер пересоздается: `./nginx/setup.sh` или `./compose.sh nginx up -d --force-recreate`. Посмотреть результат рендера: `./nginx/setup.sh --show`. Неизвестные имена nginx не обслуживает (соединение закрывается).

### keycloak

Прод: только Keycloak, БД на внешнем Postgres (`keycloak/.env`), realm импортируется из `realm-export.json` один раз на пустую БД. Dev (`--dev`): Keycloak и одноразовый postgres, realm без LDAP, пользователь `admin_dev/admin_dev`, админка `admin/admin`, `http://localhost:8080`.

Секреты в `realm-export.json` не хранятся, после первого импорта задаются через `kcadm.sh` (команды печатает `keycloak/setup.sh`): пароль LDAP, секрет клиента `streamlit` (равен `CLIENT_STREAMLIT_SECRET` приложения), redirect URI клиента `streamlit` для уже существующего realm (`https://<HOST_UI>/oauth2callback` есть в экспорте только для новых установок).

Бэкап: дамп внешней БД и офлайн-экспорт realm.

```
pg_dump -h <db-host> -U keycloak -d keycloak -F c -f keycloak_db_$(date +%Y%m%d).dump
# восстановление: pg_restore -h <db-host> -U keycloak -d keycloak --clean --if-exists keycloak_db_YYYYMMDD.dump

./compose.sh keycloak stop keycloak
./compose.sh keycloak run --rm --entrypoint "" keycloak \
  /opt/keycloak/bin/kc.sh export --dir /opt/keycloak/data/backup --realm master --users skip
./compose.sh keycloak start keycloak
```

`--users skip`, чтобы не тянуть в бэкап кэш пользователей из LDAP. Быстрая сверка конфигурации без остановки:

```
curl -s -X POST "https://<HOST_AUTH>/admin/realms/master/partial-export?exportClients=true&exportGroupsAndRoles=true" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -o realm-live-snapshot.json
diff <(jq -S . keycloak/realm-export.json) <(jq -S . realm-live-snapshot.json)
```

### docker_registry

Приватный registry с htpasswd-аутентификацией и веб-интерфейсом. Наружу через nginx виден только UI, он сам проксирует `/v2/` на registry по внутренней сети, поэтому `docker login/push/pull` и браузер работают с одним адресом.

Учетные записи: `docker_registry/.env` (`REGISTRY_USER`, `REGISTRY_PASSWORD`), `setup.sh` создает `auth/htpasswd` при первом запуске и чистит его от посторонних строк, `./docker_registry/setup.sh --add-user` добавляет или меняет пользователя. Изменение учетной записи, которой пользуется CI, требует обновить его секреты.

Зеркало образов для прода живет здесь же, в пространстве имен `mirror/`.

Garbage collection после удаления образов через UI (сначала `--dry-run`):

```
./compose.sh docker_registry exec registry bin/registry garbage-collect --dry-run /etc/distribution/config.yml
./compose.sh docker_registry exec registry bin/registry garbage-collect /etc/distribution/config.yml
```

Бэкап volume `docker_registry_registry_data`:

```
docker run --rm -v docker_registry_registry_data:/data -v $(pwd):/backup alpine \
  tar czf /backup/registry_data_$(date +%Y%m%d).tar.gz -C /data .
```

### observability

Loki хранит логи 90 дней (`loki-config.yml`), Alloy собирает stdout контейнеров через Docker socket, Grafana показывает. Alloy берет только контейнеры, чьи имена подходят под `APP_CONTAINER_REGEX` из корневого `.env`, и ставит им метку `app="asu"`; дашборды фильтруют по ней и от имен контейнеров не зависят. Grafana снаружи через nginx (`HOST_GRAFANA`), локально `http://127.0.0.1:3001`, логин `admin` и пароль из `observability/.env`.

Поиск по логам через LogQL, например `{app="asu"} | json | username="ivanov"`.

На хостах без основного стека (приложение или Valhalla на другом сервере) поднимается только агент: `./setup.sh --only observability --agent`. Он пишет в Loki по `LOKI_URL` через `app-network`, Loki для этого имеет алиас `loki`.

Дашборд «АСУ ТОиР - Активность» (`grafana/provisioning/dashboards/activity.json`): запросы к API во времени и по статусам, ошибки, топ пользователей и эндпоинтов, просмотры страниц. Правки из UI в файл не попадают сами. Чтобы зафиксировать: открыть дашборд, настройки, JSON Model, сохранить поверх `activity.json`, убрать поля `id` и `version`, оставить `uid` как есть, закоммитить. Через `updateIntervalSeconds: 30` файл снова станет источником правды.

### valhalla

Маршрутизация для приложения, летний и зимний сезоны, публикация кастомных дорог. Ставится без приложения, publisher подключается позже. Подробности в [valhalla/README.md](valhalla/README.md).

## Добавление сервиса

1. Каталог `<сервис>/` с `docker-compose.yml` (образ как `${IMAGE_MIRROR:-}<имя>`, сеть `app-network` external, `container_name: infra_<сервис>`, порты на хост только `127.0.0.1` для диагностики), `.env.example`, `setup.sh` по образцу:

   ```
   #!/usr/bin/env bash
   set -euo pipefail
   cd "$(dirname "$0")"
   . ../lib.sh
   LOG_PREFIX=<сервис>
   load_root_env
   ensure_env_file . <ОБЯЗАТЕЛЬНЫЕ_ПЕРЕМЕННЫЕ>
   ensure_stack_images <сервис>
   compose <сервис> up -d $(pull_flag)
   wait_http http://127.0.0.1:<порт>/<health> 90
   ```

2. Доступ снаружи: `HOST_<СЕРВИС>=appsrvs.<сервис>` в `.env.example` и `.env`, шаблон `nginx/templates/<сервис>.conf.template` (скопировать `grafana.conf.template`, WebSocket оставить только если сервис им пользуется). Сертификат перевыпустится сам при следующем `./setup.sh`, клиентам добавить имя в DNS или hosts. Внутренние сервисы (redis) шаблон не получают.
3. Стек в список `SERVICES` в `setup.sh`, при желании путь проверки в `health_path` там же.
4. Если образ сервиса что-то скачивает с GitHub при старте, файл кладется в `<сервис>/assets/` с указанием источника, а `setup.sh` стека раскладывает его на место.

Образы нового стека автоматически попадают в `offline/list-images.sh`.

## Переименование приложения

Имя приложения в инфраструктуре живет только в `.env`:

1. Корневой `.env`: `APP_UI_UPSTREAM`, `APP_API_UPSTREAM` (имена контейнеров или алиасы нового приложения), `APP_CONTAINER_REGEX` (маска его контейнеров для логов).
2. `valhalla/.env`: `ASU_API_URL`.
3. `./setup.sh --only nginx --only observability --only valhalla`.

Логи, собранные до переименования, остаются под старыми именами контейнеров, метка `app` у них та же.

## Приложение

Что должно быть у приложения, чтобы инфраструктура его видела:

- Контейнеры в сети `app-network` с именами или алиасами `APP_UI_UPSTREAM` и `APP_API_UPSTREAM`; при нескольких серверах приложение заходит в swarm как worker и использует ту же overlay-сеть.
- `extra_hosts` с `HOST_AUTH` на `SERVER_IP`, чтобы ходить в Keycloak через nginx, и корень CA в `HOST_CUSTOM_CA_PATH`.
- Redirect URI OIDC `https://<HOST_UI>/oauth2callback` в `.env` приложения и в клиенте `streamlit` Keycloak.
- Для pull образов из registry на сервере приложения: корень в `/etc/docker/certs.d/<HOST_REGISTRY>/ca.crt`.
- Для publisher: M2M-токен с правами `custom_roads` view и edit, выпускается в приложении и записывается в `valhalla/.env`.
