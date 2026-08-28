#!/usr/bin/env bash
# Valhalla: летний и зимний тайлсеты и publisher кастомных дорог. Скрипт
# повторно запускаемый: каждый запуск делает то, что еще не сделано, и
# пишет, что осталось. Приложение для установки не нужно.
#   ./setup.sh          поднять; первая сборка тайлов (~1 час) идет в фоне
#   ./setup.sh --wait   дождаться первой сборки, до 2 часов
set -euo pipefail
cd "$(dirname "$0")"
. ../lib.sh
LOG_PREFIX=valhalla

WAIT=0
[ "${1:-}" = "--wait" ] && WAIT=1

load_root_env
ensure_env_file . TILE_URLS

FILES=custom_files
SUMMER="$FILES/summer"
WINTER="$FILES/winter"
SUMMER_PORT="$(env_value .env VALHALLA_SUMMER_PORT)"; SUMMER_PORT="${SUMMER_PORT:-8002}"
WINTER_PORT="$(env_value .env VALHALLA_WINTER_PORT)"; WINTER_PORT="${WINTER_PORT:-8003}"
TOKEN="$(env_value .env ASU_API_TOKEN)"
PUBLISHER_TAG="$(env_value .env PUBLISHER_TAG)"; PUBLISHER_TAG="${PUBLISHER_TAG:-latest}"
PUBLISHER_IMAGE="${IMAGE_MIRROR}valhalla-publisher:${PUBLISHER_TAG}"
VALHALLA_IMAGE="$(compose valhalla config --images 2>/dev/null | grep -m1 valhalla-scripted)"
SUMMER_STATUS="http://127.0.0.1:${SUMMER_PORT}/status"
WINTER_STATUS="http://127.0.0.1:${WINTER_PORT}/status"

# Publisher монтирует каталог builder-контейнеру по пути на хосте, поэтому
# HOST_FILES_DIR должен указывать на custom_files рядом с этим скриптом.
check_host_files_dir() {
  local expected="$PWD/$FILES" current
  current="$(env_value .env HOST_FILES_DIR)"
  if [ -z "$current" ]; then
    printf '\nHOST_FILES_DIR=%s\n' "$expected" >> .env
    log "HOST_FILES_DIR не был задан, записан в .env: $expected"
  elif [ "$current" != "$expected" ]; then
    warn "HOST_FILES_DIR=$current в .env, а каталог скрипта $expected: publisher будет монтировать builder'у путь из .env"
  fi
}

# Образ valhalla работает от UID 59999 и должен владеть каталогом данных.
own_files_dir() {
  [ "$(uname -s)" = Linux ] || return 0
  mkdir -p "$SUMMER" "$WINTER"
  [ "$(stat -c %u "$FILES")" = 59999 ] && return 0
  log "Каталог $FILES отдаем UID 59999 (пользователь образа valhalla)"
  sudo chown -R 59999:59999 "$FILES" 2>/dev/null || chown -R 59999:59999 "$FILES" \
    || warn "chown не удался, выполните вручную: sudo chown -R 59999:59999 $PWD/$FILES"
}

ensure_publisher_image() {
  if docker image inspect "$PUBLISHER_IMAGE" >/dev/null 2>&1; then
    log "Образ publisher на месте: $PUBLISHER_IMAGE"
  elif [ -n "$IMAGE_MIRROR" ]; then
    log "Берем publisher из зеркала: $PUBLISHER_IMAGE"
    compose valhalla pull publisher
  elif [ "$OFFLINE" = 1 ]; then
    die "Нет образа $PUBLISHER_IMAGE при OFFLINE=1: загрузите бандл (offline/load.sh)"
  else
    log "Собираем образ publisher"
    compose valhalla build publisher
  fi
}

# Без default_speeds.json образ качает его с GitHub при первой сборке,
# а в проде GitHub недоступен: файл лежит в репозитории.
seed_default_speeds() {
  local season
  for season in summer winter; do
    mkdir -p "$FILES/$season"
    if [ ! -f "$FILES/$season/default_speeds.json" ]; then
      cp assets/default_speeds.json "$FILES/$season/"
      log "default_speeds.json положен в $FILES/$season"
    fi
  done
}

ensure_base_map() {
  [ -f "$SUMMER/base_map.osm.pbf" ] && return 0
  [ "$OFFLINE" = 1 ] && die "Нет $SUMMER/base_map.osm.pbf при OFFLINE=1: перенесите карту бандлом (offline/bundle.sh --with-map)"
  log "Готовим базовую карту: скачивание Geofabrik (~3.5 ГБ) и слияние в один PBF"
  ./prepare_pbf.sh summer
}

wait_first_build() {
  local deadline
  if [ "$WAIT" != 1 ]; then
    log "Идет первая сборка тайлов, около часа. Прогресс: docker logs -f infra_valhalla_summer"
    log "Когда закончится, запустите ./setup.sh снова: он допатчит конфиг и поднимет зимний сезон. Или сразу ./setup.sh --wait"
    exit 0
  fi
  log "Идет первая сборка тайлов, ждем до 2 часов"
  deadline=$(( $(date +%s) + 7200 ))
  until curl -sf --max-time 5 "$SUMMER_STATUS" >/dev/null 2>&1; do
    [ "$(date +%s)" -lt "$deadline" ] || die "Сборка не завершилась за 2 часа: docker logs infra_valhalla_summer"
    log "сборка: $(docker logs --tail 1 infra_valhalla_summer 2>&1 | tail -c 120)"
    sleep 60
  done
  log "Летний тайлсет собран"
}

# Дефолтные лимиты Valhalla ломают матрицы дальше 400 км, публикация
# патчит конфиг сама, после первой сборки это делаем здесь.
patch_summer_config() {
  grep -q '"max_matrix_distance": 10000000' "$SUMMER/valhalla.json" && return 0
  log "Патчим valhalla.json летнего сезона: лимиты матриц, связность, второй проход"
  compose valhalla run --rm --no-deps publisher python -m publisher.cli patch-config /custom_files/summer/valhalla.json
  compose valhalla restart valhalla-summer
  wait_http "$SUMMER_STATUS" 300 || die "Летний сервис не поднялся после патча: docker logs infra_valhalla_summer"
}

# Без нарисованных зимников зимний граф совпадает с летним, поэтому
# первый зимний тайлсет это копия летнего. Копируется все, включая
# file_hashes.txt: при несовпадении хэшей образ пересобирал бы тайлы час.
bootstrap_winter() {
  if [ -f "$WINTER/valhalla_tiles.tar" ]; then
    log "Зимний тайлсет уже наполнен"
    return 0
  fi
  log "Наполняем зимний сезон копией летнего (~11 ГБ)"
  container_running infra_valhalla_winter && compose valhalla --profile winter stop valhalla-winter
  cp -a "$SUMMER/." "$WINTER/"
  if [ "$(uname -s)" = Linux ]; then chown -R 59999:59999 "$WINTER" 2>/dev/null || true; fi
}

check_host_files_dir
own_files_dir
ensure_publisher_image
ensure_image "$VALHALLA_IMAGE"
seed_default_speeds
ensure_base_map

compose valhalla up -d $(pull_flag) valhalla-summer
if ! wait_http "$SUMMER_STATUS" 180; then
  if [ -f "$SUMMER/valhalla_tiles.tar" ]; then
    die "Летний сервис не отвечает, хотя тайлы есть: docker logs infra_valhalla_summer"
  fi
  wait_first_build
fi
patch_summer_config

bootstrap_winter
compose valhalla --profile winter up -d $(pull_flag) valhalla-winter
wait_http "$WINTER_STATUS" 300 || die "Зимний сервис не поднялся: docker logs infra_valhalla_winter"

if [ -n "$TOKEN" ]; then
  compose valhalla up -d $(pull_flag) publisher
  log "publisher запущен и опрашивает заявки приложения"
else
  log "ASU_API_TOKEN пуст, publisher не запущен. Когда приложение поднято: выпустить M2M-токен с правами custom_roads (README приложения), вписать в .env, запустить ./setup.sh снова"
  log "Зимники: после публикации дорог с season=winter выполнить ./rebuild.sh winter"
fi
log "Готово: летний $SUMMER_STATUS, зимний $WINTER_STATUS, снаружи https://${HOST_ROUTE:-appsrvs.route}/summer/ и /winter/"
