#!/usr/bin/env bash
# Можно ли собрать подложку на этой машине: доступны ли исходники и образы,
# хватает ли места. Ничего не качает и не меняет, только проверяет.
#
# Запускать до сборки, особенно на сервере: в проде закрыт ghcr.io, а адреса
# служебных данных planetiler ведут не на Geofabrik и могут быть закрыты тоже.
#
# Использование:
#   ./check_sources.sh
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"
. ../lib.sh
LOG_PREFIX=tiles-check

load_root_env
ensure_env_file .
# shellcheck disable=SC1091
. ./sources.env

PBF_DIR="$(env_value .env TILES_PBF_DIR)"; PBF_DIR="${PBF_DIR:-../valhalla/custom_files/summer}"
PBF_NAME="$(env_value .env TILES_PBF_NAME)"; PBF_NAME="${PBF_NAME:-base_map.osm.pbf}"
PBF="$PBF_DIR/$PBF_NAME"

problems=0

note_problem() {
    warn "$1"
    problems=$((problems + 1))
}

check_url() {
    local url="$1" name code
    name="$(basename "$url")"
    if [ -f "data/sources/$name" ]; then
        log "уже скачан: $name ($(du -h "data/sources/$name" | cut -f1))"
        return 0
    fi
    code="$(curl -sIL -o /dev/null -w '%{http_code}' --max-time 20 "$url" 2>/dev/null || true)"
    case "$code" in
        2*) log "доступен: $url" ;;
        000 | "") note_problem "нет ответа: $url" ;;
        *) note_problem "недоступен (код $code): $url" ;;
    esac
}

check_image() {
    local image="$1"
    if docker image inspect "$image" >/dev/null 2>&1; then
        log "образ на месте: $image"
    elif docker manifest inspect "$image" >/dev/null 2>&1; then
        log "образ доступен: $image"
    else
        note_problem "образ не скачать: $image"
    fi
}

log "===== исходники ====="
for url in $PLANETILER_URLS; do
    check_url "$url"
done
check_url "$COUNTRIES_URL"
check_url "$REGIONS_URL"

log "===== образы ====="
if ! docker info >/dev/null 2>&1; then
    note_problem "docker не отвечает, образы не проверить"
else
    while read -r image; do
        [ -n "$image" ] && check_image "$image"
    done < <(compose tiles --profile build config --images 2>/dev/null | sort -u)
fi

log "===== выгрузка и место ====="
if [ -f "$PBF" ]; then
    pbf_gb="$(du -m "$PBF" | cut -f1)"
    pbf_gb=$((pbf_gb / 1024))
    # planetiler просит 5-10 размеров выгрузки, берем середину
    need_gb=$((pbf_gb * 8))
    free_gb="$(df -Pm . | awk 'NR==2 {print int($4 / 1024)}')"
    log "выгрузка: $PBF (${pbf_gb} ГБ)"
    if [ "$free_gb" -ge "$need_gb" ]; then
        log "места: свободно ${free_gb} ГБ, нужно около ${need_gb} ГБ"
    else
        note_problem "мало места: свободно ${free_gb} ГБ, нужно около ${need_gb} ГБ"
    fi
else
    note_problem "нет выгрузки $PBF, без нее собирать нечего"
fi

echo
if [ "$problems" -eq 0 ]; then
    log "Все на месте, можно собирать: ./build.sh и ./build_countries.sh"
    exit 0
fi

warn "Помех: $problems. Что делать:"
cat >&2 <<'HINT'
    образы недоступны   ./offline/mirror.sh --only-blocked с машины с интернетом,
                        либо бандл: offline/bundle.sh и offline/load.sh
    исходники закрыты   скачать их на машине с интернетом и привезти каталог
                        tiles/data/sources целиком, это около 1.4 ГБ
    мало места          освободить диск или собрать на другой машине
    собирать негде      собрать где есть интернет и привезти результат:
                        offline/bundle.sh --with-basemap, затем offline/load.sh
HINT
exit 1
