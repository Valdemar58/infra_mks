#!/usr/bin/env bash
# Сборка слоя стран: полигоны всех стран мира на зумах 0-6. Слой дает сушу за
# пределами основной выгрузки, выделение России цветом и границы по российской
# точке зрения.
#
# Три шага: скачать наборы Natural Earth, сшить геометрию (merge_countries.py),
# собрать тайлы planetiler по схеме countries.yml.
#
# Запускается на машине с интернетом, качает около 19 МБ исходников в
# data/sources. Считает минуты, тяжелых требований нет.
#
# Использование:
#   ./build_countries.sh
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"
. ../lib.sh
LOG_PREFIX=tiles-countries

load_root_env
ensure_env_file .
# Адреса исходников общие с check_sources.sh
# shellcheck disable=SC1091
. ./sources.env

mkdir -p data/sources
for url in "$COUNTRIES_URL" "$REGIONS_URL"; do
    name="$(basename "$url")"
    if [ ! -f "data/sources/$name" ]; then
        log "Скачиваем $name"
        curl -fL --retry 5 --retry-delay 10 -o "data/sources/$name.part" "$url"
        mv "data/sources/$name.part" "data/sources/$name"
    fi
done

log "Сшиваем геометрию стран"
"$DIR/../compose.sh" tiles --profile build run --rm --no-deps geometry

log "Собираем тайлы слоя стран"
# generate-custom всегда перезаписывает вывод, --force не нужен
"$DIR/../compose.sh" tiles --profile build run --rm --no-deps planetiler \
    generate-custom --schema=/countries.yml \
    --output=/data/countries.new.mbtiles

mv -f data/countries.new.mbtiles data/countries.mbtiles
log "Готово: $DIR/data/countries.mbtiles ($(du -h data/countries.mbtiles | cut -f1))"

if container_running infra_tiles; then
    log "Перезапускаем tileserver, чтобы он открыл новый файл"
    compose tiles restart tileserver
fi
