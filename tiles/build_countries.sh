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

# Точка зрения задается набором стран: rus это де-юре российская. Другие
# варианты лежат по тому же адресу с суффиксом ukr, chn и так далее
COUNTRIES_URL=https://naciscdn.org/naturalearth/10m/cultural/ne_10m_admin_0_countries_rus.zip
REGIONS_URL=https://naciscdn.org/naturalearth/10m/cultural/ne_10m_admin_1_states_provinces.zip

load_root_env
ensure_env_file .

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
