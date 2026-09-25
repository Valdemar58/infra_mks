"""Сшивка геометрии стран для слоя countries.

Natural Earth версии 5.1.1 вышел раньше сентября 2022 года: Крым в нем уже
внутри России, а Донецкая, Луганская, Запорожская и Херсонская области еще нет.
Планетайлер пространственных операций не умеет, поэтому области переносятся
здесь: они берутся из слоя регионов, объединяются с Россией и вычитаются из
Украины.

Здесь же считаются линии государственных границ: пересечение контуров соседних
стран. Из тайлов OSM их взять нельзя, в них у пограничных линий нет полей с
кодами стран, поэтому линию по границе 1991 года нечем отличить от прочих.
Береговая линия в такой слой не попадает, она ни с кем не общая.

Запускается контейнером из build_countries.sh, на хост ничего не ставится.
"""

import json
import zipfile
from pathlib import Path

import shapefile
from shapely.geometry import MultiPolygon, Polygon, mapping, shape
from shapely.ops import linemerge, unary_union
from shapely.strtree import STRtree

SOURCES = Path("/data/sources")
COUNTRIES_ZIP = SOURCES / "ne_10m_admin_0_countries_rus.zip"
REGIONS_ZIP = SOURCES / "ne_10m_admin_1_states_provinces.zip"
OUT = SOURCES / "countries_merged.geojson"
OUT_BORDERS = SOURCES / "borders_merged.geojson"

# Области, которые переносятся в Россию
MOVED_REGIONS = {"Donets'k", "Luhans'k", "Zaporizhzhya", "Kherson"}
# Полигон территорий 2014 года, он весь внутри перенесенных областей
BREAKAWAY_CODE = "C02"


def read_layer(path: Path):
    """Записи шейпфайла из zip без распаковки на диск."""
    with zipfile.ZipFile(path) as archive:
        base = next(n for n in archive.namelist() if n.endswith(".shp"))[:-4]
        with (
            archive.open(f"{base}.shp") as shp,
            archive.open(f"{base}.dbf") as dbf,
            archive.open(f"{base}.shx") as shx,
        ):
            reader = shapefile.Reader(shp=shp, dbf=dbf, shx=shx, encoding="utf-8", encodingErrors="replace")
            return [(rec.as_dict(), shape(geom.__geo_interface__)) for rec, geom in zip(reader.records(), reader.shapes(), strict=True)]


def field(record: dict, *names: str):
    lowered = {key.lower(): value for key, value in record.items()}
    for name in names:
        value = lowered.get(name.lower())
        if value not in (None, ""):
            return value
    return None


def without_holes(geom):
    """Полигон без внутренних колец.

    Слой регионов обходит дыркой территории 2014 года, и без этого внутри
    перенесенных областей остается чужой анклав.
    """
    parts = geom.geoms if isinstance(geom, MultiPolygon) else [geom]
    return unary_union([Polygon(part.exterior) for part in parts])


countries = read_layer(COUNTRIES_ZIP)
regions = read_layer(REGIONS_ZIP)

moved = [
    geom
    for record, geom in regions
    if field(record, "adm0_a3") == "UKR" and field(record, "name") in MOVED_REGIONS
]
if len(moved) != len(MOVED_REGIONS):
    found = sorted(field(r, "name") for r, _ in regions if field(r, "adm0_a3") == "UKR")
    raise SystemExit(f"Нашлось {len(moved)} областей из {len(MOVED_REGIONS)}, есть такие: {found}")

# Обрубки 2014 года лежат внутри перенесенных областей и идут туда же.
# Записей с такой территорией в наборе несколько, часть без кода страны
breakaway = [geom for record, geom in countries if field(record, "ADM0_A3_RU") == BREAKAWAY_CODE]
moved_union = without_holes(unary_union(moved + breakaway).buffer(0))

features = []
for record, geom in countries:
    code = field(record, "ADM0_A3")
    name = field(record, "NAME")

    # Перенесенная территория вычитается у всех, кроме России: иначе поверх
    # нее остаются чужие полигоны и рисуются анклавами
    if code == "RUS":
        geom = unary_union([geom.buffer(0), moved_union])
    else:
        geom = geom.buffer(0).difference(moved_union)

    if geom.is_empty:
        continue
    features.append(
        {
            "type": "Feature",
            "properties": {
                "iso_a2": field(record, "ISO_A2") or "",
                "iso_a3": code or "",
                "name": name or "",
            },
            "geometry": mapping(geom),
        }
    )

OUT.write_text(json.dumps({"type": "FeatureCollection", "features": features}), encoding="utf-8")

def only_lines(geom):
    """Линейные части геометрии.

    В стыке трех стран пересечение контуров дает точку, а смешанную
    геометрию сборщик тайлов пропускает молча.
    """
    if geom.is_empty:
        return []
    if geom.geom_type == "LineString":
        return [geom]
    if geom.geom_type in ("MultiLineString", "GeometryCollection"):
        return [part for sub in geom.geoms for part in only_lines(sub)]
    return []


# Линии границ: общий контур пары соседей. Индекс нужен, чтобы не перебирать
# все пары стран
geometries = [shape(feature["geometry"]).buffer(0) for feature in features]
tree = STRtree(geometries)
shared = []
for i, geom in enumerate(geometries):
    for j in tree.query(geom):
        if j <= i:
            continue
        shared.extend(only_lines(geom.boundary.intersection(geometries[j].boundary)))

# Куски сшиваются в длинные линии: иначе на обзорных зумах каждый короткий
# отрезок отбрасывается сборщиком как слишком мелкий и границ не видно вовсе
borders = linemerge(unary_union(shared))
OUT_BORDERS.write_text(
    json.dumps(
        {
            "type": "FeatureCollection",
            "features": [{"type": "Feature", "properties": {}, "geometry": mapping(borders)}],
        }
    ),
    encoding="utf-8",
)

merged_count = len(borders.geoms) if borders.geom_type == "MultiLineString" else 1
print(f"Стран в слое: {len(features)}, перенесено областей: {len(moved)}")
print(f"Границ: {len(shared)} участков сшито в {merged_count} линий, длина {borders.length:.1f} градусов")
print(f"Файлы: {OUT}, {OUT_BORDERS}")
