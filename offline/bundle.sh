#!/usr/bin/env bash
# Бандл для сервера без интернета: образы (docker save), файлы, которые
# образы иначе качают с GitHub, по желанию карта, готовые летние тайлы и
# подложка карт. Запускается на машине с интернетом, на сервере
# разворачивается load.sh.
#   ./bundle.sh [--with-map] [--with-tiles] [--with-basemap] [каталог]
# По умолчанию каталог offline/bundle. --with-tiles это тайлы маршрутизации
# Valhalla, --with-basemap это подложка карт.
set -euo pipefail
cd "$(dirname "$0")/.."
. ./lib.sh
LOG_PREFIX=bundle

WITH_MAP=0 WITH_TILES=0 WITH_BASEMAP=0 OUT=offline/bundle
while [ $# -gt 0 ]; do
  case "$1" in
    --with-map) WITH_MAP=1 ;;
    --with-tiles) WITH_TILES=1 ;;
    --with-basemap) WITH_BASEMAP=1 ;;
    *) OUT="$1" ;;
  esac
  shift
done

load_root_env
export IMAGE_MIRROR=""
mkdir -p "$OUT"
mapfile -t IMAGES < <(offline/list-images.sh)

for image in "${IMAGES[@]}"; do
  docker image inspect "$image" >/dev/null 2>&1 && continue
  case "$image" in
    valhalla-publisher:*) log "Собираем $image"; compose valhalla build publisher ;;
    *) log "Скачиваем $image"; docker pull "$image" ;;
  esac
done

printf '%s\n' "${IMAGES[@]}" > "$OUT/images.txt"
log "Сохраняем ${#IMAGES[@]} образов в $OUT/images.tar"
docker save -o "$OUT/images.tar" "${IMAGES[@]}"
cp valhalla/assets/default_speeds.json "$OUT/"
FILES=(images.tar default_speeds.json)

if [ "$WITH_MAP" = 1 ]; then
  [ -f valhalla/custom_files/summer/base_map.osm.pbf ] || die "Нет valhalla/custom_files/summer/base_map.osm.pbf"
  cp valhalla/custom_files/summer/base_map.osm.pbf "$OUT/"
  FILES+=(base_map.osm.pbf)
fi
if [ "$WITH_TILES" = 1 ]; then
  [ -f valhalla/custom_files/summer/valhalla_tiles.tar ] || die "Летний тайлсет еще не собран"
  log "Упаковываем летний тайлсет (~11 ГБ)"
  tar -cf "$OUT/tiles_summer.tar" -C valhalla/custom_files summer
  FILES+=(tiles_summer.tar)
fi
if [ "$WITH_BASEMAP" = 1 ]; then
  [ -f tiles/data/basemap.mbtiles ] || die "Нет tiles/data/basemap.mbtiles: соберите подложку ./tiles/build.sh"
  [ -f tiles/data/countries.mbtiles ] || die "Нет tiles/data/countries.mbtiles: соберите слой стран ./tiles/build_countries.sh"
  log "Копируем подложку карт ($(du -h tiles/data/basemap.mbtiles | cut -f1)) и слой стран"
  cp tiles/data/basemap.mbtiles tiles/data/countries.mbtiles "$OUT/"
  FILES+=(basemap.mbtiles countries.mbtiles)
fi

( cd "$OUT" && sha256sum "${FILES[@]}" > MANIFEST )
log "Готово: $OUT ($(du -sh "$OUT" | cut -f1)). На сервере: offline/load.sh <каталог>"
