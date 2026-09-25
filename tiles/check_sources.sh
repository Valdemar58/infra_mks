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
missing_files=()
image_problem=0
disk_problem=0

note_problem() {
    warn "$1"
    problems=$((problems + 1))
}

note_missing_file() {
    local name="$1" len="$2"
    if [ "${len:-0}" -gt 0 ]; then
        missing_files+=("$name ($((len / 1048576)) МБ)")
    else
        missing_files+=("$name")
    fi
}

# Кусок файла для замера: больше, чем успевает пройти до обрыва
SPEED_BYTES=16777216
SPEED_MAX_SECONDS=30
# Передача считается вставшей, если скорость ниже этого столько секунд
STALL_BYTES_PER_SECOND=10240
STALL_SECONDS=8
# Дольше этого качать бессмысленно, проще привезти файлы
MAX_DOWNLOAD_SECONDS=1800

human_time() {
    local s="$1"
    if [ "$s" -lt 120 ]; then
        echo "${s} с"
    elif [ "$s" -lt 7200 ]; then
        echo "$((s / 60)) мин"
    else
        echo "$((s / 3600)) ч"
    fi
}

check_url() {
    local url="$1" name head code len speed eta
    name="$(basename "$url")"
    if [ -f "data/sources/$name" ]; then
        log "уже скачан: $name ($(du -h "data/sources/$name" | cut -f1))"
        return 0
    fi

    head="$(curl -sIL --max-time 20 "$url" 2>/dev/null || true)"
    code="$(printf '%s\n' "$head" | awk '/^HTTP/ {c=$2} END {print c}')"
    case "$code" in
        2*) ;;
        "") note_missing_file "$name" 0; note_problem "нет ответа: $url"; return 0 ;;
        *) note_missing_file "$name" 0; note_problem "недоступен (код $code): $url"; return 0 ;;
    esac

    # Заголовки приходят мгновенно даже при мертвом канале, а передача умеет
    # начаться бодро и встать через несколько секунд. Поэтому тянем кусок
    # подольше и следим, не остановилась ли она
    len="$(printf '%s\n' "$head" | tr -d '\r' | grep -i '^content-length:' | tail -1 | awk '{print $2 + 0}')"
    local out rc=0 got spent
    out="$(curl -s -o /dev/null \
        -r "0-$((SPEED_BYTES - 1))" \
        --speed-limit "$STALL_BYTES_PER_SECOND" --speed-time "$STALL_SECONDS" \
        --max-time "$SPEED_MAX_SECONDS" \
        -w '%{size_download} %{time_total} %{speed_download}' \
        "$url" 2>/dev/null)" || rc=$?
    got="$(printf '%s' "$out" | awk '{print $1 + 0}')"
    spent="$(printf '%s' "$out" | awk '{print int($2)}')"
    speed="$(printf '%s' "$out" | awk '{print int($3)}')"

    # 28 это обрыв по --speed-time или по --max-time
    if [ "$rc" = 28 ]; then
        note_missing_file "$name" "$len"
        note_problem "передача встала: получено $((got / 1024)) КБ за ${spent} с, дальше тишина ($url)"
        return 0
    fi
    if [ "$rc" != 0 ] || [ "$got" -eq 0 ]; then
        note_missing_file "$name" "$len"
        note_problem "не качается (код curl $rc): $url"
        return 0
    fi
    if [ "$speed" -lt 1024 ]; then
        note_missing_file "$name" "$len"
        note_problem "канал стоит (${speed} Б/с): $url"
        return 0
    fi

    eta=$((len / speed))
    if [ "$len" -gt 0 ] && [ "$eta" -gt "$MAX_DOWNLOAD_SECONDS" ]; then
        note_missing_file "$name" "$len"
        note_problem "слишком медленно ($((speed / 1024)) КБ/с, качать $(human_time "$eta")): $url"
        return 0
    fi
    log "доступен: $name ($((speed / 1024)) КБ/с на $((got / 1024 / 1024)) МБ, качать $(human_time "$eta"))"
}

check_image() {
    local image="$1"
    if docker image inspect "$image" >/dev/null 2>&1; then
        log "образ на месте: $image"
    elif docker manifest inspect "$image" >/dev/null 2>&1; then
        log "образ доступен: $image"
    else
        image_problem=1
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
    image_problem=1
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
        disk_problem=1
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

if [ "${#missing_files[@]}" -gt 0 ]; then
    {
        echo "  Скачать на машине с интернетом и положить в tiles/data/sources:"
        printf '    %s\n' "${missing_files[@]}"
        echo "  Скрипты скачанное не перекачивают, остальные файлы трогать не нужно."
    } >&2
fi

if [ "$image_problem" = 1 ]; then
    {
        echo "  Образы: ./offline/mirror.sh --only-blocked с машины с интернетом"
        echo "  либо бандл: offline/bundle.sh и offline/load.sh"
    } >&2
fi

if [ "$disk_problem" = 1 ]; then
    echo "  Место: освободить диск или собирать на другой машине" >&2
fi

{
    echo "  Если собирать здесь не выходит вовсе, соберите там, где есть интернет,"
    echo "  и привезите результат: offline/bundle.sh --with-basemap, затем offline/load.sh"
} >&2
exit 1
