#!/usr/bin/env bash
# Подготовка базовой карты для Valhalla: скачивает выгрузки Geofabrik из
# TILE_URLS (.env) и сливает их в единый base_map.osm.pbf. Несколько PBF
# напрямую Valhalla отдавать нельзя: сборка тайлов из нескольких файлов
# нестабильна и падает (Aborted в valhalla_build_tiles), поэтому карта
# всегда готовится одним файлом. Мерж выполняет osmium из образа
# publisher, на хост ничего не устанавливается.
#
# Использование:
#   ./prepare_pbf.sh [summer|winter]
set -euo pipefail

SEASON="${1:-summer}"
DIR="$(cd "$(dirname "$0")" && pwd)"
DEST="$DIR/custom_files/$SEASON"
ENV_FILE="$DIR/.env"

cd "$DIR"

[ -f "$ENV_FILE" ] || { echo "Нет $ENV_FILE - скопируйте .env.example"; exit 1; }
TILE_URLS="$(grep -E '^TILE_URLS=' "$ENV_FILE" | tail -1 | cut -d= -f2-)"
[ -n "$TILE_URLS" ] || { echo "TILE_URLS пуст в $ENV_FILE"; exit 1; }

mkdir -p "$DEST"
files=()
for url in $TILE_URLS; do
    name="$(basename "$url")"
    if [ ! -f "$DEST/$name" ]; then
        echo "Скачиваем $name"
        curl -fL --retry 3 -o "$DEST/$name" "$url"
    fi
    files+=("/custom_files/$SEASON/$name")
done

if [ "${#files[@]}" -eq 1 ]; then
    mv -f "$DEST/$(basename "${files[0]}")" "$DEST/base_map.osm.pbf"
    echo "Готово: единственный файл переименован в base_map.osm.pbf"
    exit 0
fi

echo "Мержим ${#files[@]} файлов в base_map.osm.pbf"
# Через compose.sh, чтобы образ publisher брался с учетом IMAGE_MIRROR
"$DIR/../compose.sh" valhalla run --rm --no-deps --entrypoint osmium publisher \
    merge "${files[@]}" -o "/custom_files/$SEASON/base_map.osm.pbf" --overwrite

for f in "${files[@]}"; do
    rm -f "$DEST/$(basename "$f")"
done
echo "Готово: $DEST/base_map.osm.pbf"
