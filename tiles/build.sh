#!/usr/bin/env bash
# Сборка подложки карт: planetiler превращает выгрузку OSM в векторные тайлы
# data/basemap.mbtiles, из которых tileserver-gl рендерит растр на лету.
#
# Запускается на машине с интернетом: первый запуск качает около 1.4 ГБ
# служебных данных (океанские полигоны, Natural Earth, осевые линии озер) в
# data/sources и дальше переиспользует их. Без интернета сборку не запускают,
# готовый файл везут бандлом: offline/bundle.sh --with-basemap.
#
# Требования: SSD и свободного места 5-10 размеров выгрузки, памяти Java
# примерно половина ее размера (TILES_BUILD_XMX в .env).
#
# Границы берутся из заголовка выгрузки. Тайлы делаются для всех клеток,
# которые пересекают эти границы, и внутри них данные мира полные, поэтому
# обзорные масштабы выглядят целыми. Значение world в TILES_BOUNDS рисует
# весь мир и раздувает архив в разы, ставить его не нужно.
#
# Использование:
#   ./build.sh [путь к .osm.pbf]
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"
. ../lib.sh
LOG_PREFIX=tiles-build

load_root_env
ensure_env_file .

PBF_DIR="$(env_value .env TILES_PBF_DIR)"; PBF_DIR="${PBF_DIR:-../valhalla/custom_files/summer}"
PBF_NAME="$(env_value .env TILES_PBF_NAME)"; PBF_NAME="${PBF_NAME:-base_map.osm.pbf}"
MAXZOOM="$(env_value .env TILES_MAXZOOM)"; MAXZOOM="${MAXZOOM:-14}"
BOUNDS="$(env_value .env TILES_BOUNDS)"

if [ $# -ge 1 ]; then
    [ -f "$1" ] || die "Нет файла $1"
    PBF_DIR="$(cd "$(dirname "$1")" && pwd)"
    PBF_NAME="$(basename "$1")"
fi

[ -f "$PBF_DIR/$PBF_NAME" ] || die "Нет выгрузки $PBF_DIR/$PBF_NAME. Карту Valhalla готовит ./valhalla/prepare_pbf.sh summer"

mkdir -p data/sources data/tmp

# Имя промежуточного файла оканчивается на .mbtiles: формат архива planetiler
# определяет по расширению и на постороннем останавливается
args=(
    "--osm_path=/pbf/$PBF_NAME"
    "--output=/data/basemap.new.mbtiles"
    "--download"
    "--download_dir=/data/sources"
    "--tmpdir=/data/tmp"
    "--maxzoom=$MAXZOOM"
    "--force"
)
[ -n "$BOUNDS" ] && args+=("--bounds=$BOUNDS")

log "Собираем подложку из $PBF_NAME до z$MAXZOOM, на выгрузке в несколько гигабайт это часы"
# Через compose.sh, чтобы образ planetiler брался с учетом IMAGE_MIRROR
TILES_PBF_DIR="$PBF_DIR" "$DIR/../compose.sh" tiles --profile build \
    run --rm --no-deps planetiler "${args[@]}"

mv -f data/basemap.new.mbtiles data/basemap.mbtiles
log "Готово: $DIR/data/basemap.mbtiles ($(du -h data/basemap.mbtiles | cut -f1))"

if container_running infra_tiles; then
    log "Перезапускаем tileserver, чтобы он открыл новый файл"
    compose tiles restart tileserver
fi
