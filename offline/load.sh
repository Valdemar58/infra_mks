#!/usr/bin/env bash
# Разворачивает бандл offline/bundle.sh на сервере без интернета: образы,
# default_speeds.json, при наличии карта, готовые летние тайлы и подложка карт.
#   ./load.sh [каталог бандла]   по умолчанию offline/bundle
set -euo pipefail
cd "$(dirname "$0")/.."
. ./lib.sh
LOG_PREFIX=load

BUNDLE="${1:-offline/bundle}"
[ -f "$BUNDLE/MANIFEST" ] || die "Нет $BUNDLE/MANIFEST"
load_root_env

log "Проверяем контрольные суммы"
( cd "$BUNDLE" && sha256sum -c MANIFEST )

log "Загружаем образы"
docker load -i "$BUNDLE/images.tar"
if [ -n "$IMAGE_MIRROR" ]; then
  while read -r image; do
    [ -n "$image" ] && docker tag "$image" "${IMAGE_MIRROR}${image}"
  done < "$BUNDLE/images.txt"
  log "Образы дополнительно помечены префиксом $IMAGE_MIRROR"
fi

for season in summer winter; do
  mkdir -p "valhalla/custom_files/$season"
  if [ ! -f "valhalla/custom_files/$season/default_speeds.json" ]; then
    cp "$BUNDLE/default_speeds.json" "valhalla/custom_files/$season/"
  fi
done

if [ -f "$BUNDLE/tiles_summer.tar" ] && [ ! -f valhalla/custom_files/summer/valhalla_tiles.tar ]; then
  log "Распаковываем готовые летние тайлы"
  tar -xf "$BUNDLE/tiles_summer.tar" -C valhalla/custom_files
elif [ -f "$BUNDLE/base_map.osm.pbf" ] && [ ! -f valhalla/custom_files/summer/base_map.osm.pbf ]; then
  cp "$BUNDLE/base_map.osm.pbf" valhalla/custom_files/summer/
  log "Карта положена в valhalla/custom_files/summer"
fi

for map in basemap countries; do
  if [ -f "$BUNDLE/$map.mbtiles" ] && [ ! -f "tiles/data/$map.mbtiles" ]; then
    mkdir -p tiles/data
    cp "$BUNDLE/$map.mbtiles" tiles/data/
    log "Файл $map.mbtiles положен в tiles/data"
  fi
done

log "Готово. Дальше: OFFLINE=1 в .env и ./setup.sh"
