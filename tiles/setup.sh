#!/usr/bin/env bash
# Подложка карт: tileserver-gl на готовом data/basemap.mbtiles. Скрипт
# повторно запускаемый: каждый запуск делает то, что еще не сделано.
# Карту здесь не собираем, ее готовит build.sh на машине с интернетом.
set -euo pipefail
cd "$(dirname "$0")"
. ../lib.sh
LOG_PREFIX=tiles

load_root_env
ensure_env_file .

# nginx и сертификат делаются раньше этого стека, поэтому имя должно быть в
# корневом .env до первого ./setup.sh: без него шаблон nginx молча не
# сработает, а SAN сертификата не покроет подложку.
[ -n "${HOST_TILES:-}" ] || die "Нет HOST_TILES в корневом .env. Добавьте HOST_TILES=appsrvs.tiles и перевыпустите сертификат: ./certs/setup.sh"

PORT="$(env_value .env TILES_PORT)"; PORT="${PORT:-8081}"

if [ ! -f data/basemap.mbtiles ]; then
    die "Нет $PWD/data/basemap.mbtiles.
    На машине с интернетом: ./tiles/build.sh
    Перенос на сервер: offline/bundle.sh --with-basemap, затем offline/load.sh"
fi

if [ ! -f data/countries.mbtiles ]; then
    die "Нет $PWD/data/countries.mbtiles, без него стиль останется без суши за пределами выгрузки.
    На машине с интернетом: ./tiles/build_countries.sh
    Перенос на сервер: offline/bundle.sh --with-basemap, затем offline/load.sh"
fi

ensure_stack_images tiles
# shellcheck disable=SC2046
compose tiles up -d $(pull_flag)

wait_http "http://127.0.0.1:${PORT}/health" 120 || die "tileserver не поднялся: docker logs infra_tiles"
log "tileserver отвечает на 127.0.0.1:${PORT}"

if container_running infra_nginx; then
    wait_tls "$HOST_TILES" /health 60 ||
        warn "Через nginx подложка не отвечает: проверьте nginx/templates/tiles.conf.template и сертификат (./certs/setup.sh)"
else
    warn "nginx на этом хосте не запущен, доступность снаружи не проверена"
fi

log "Подложка для приложения: MAP_TILES_URL=https://${HOST_TILES}/styles/asu/{z}/{x}/{y}.png"
