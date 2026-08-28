"""Экспорт кастомных дорог в OsmChange (.osc) для вливания в тайлы.

Формирует .osc с новыми node/way (id со смещением 10^15, чтобы не
пересекаться с OSM). Для дорог с connect_endpoints концы ломаной
привязываются к ближайшему узлу проезжей сети OSM: osmium extract
вырезает из базовой карты малые окрестности концов, затем pyosmium ищет
в них ближайший узел. Без общего узла дорога геометрически касается
сети, но графом не связана.

Полученный .osc вливается в базовую карту osmium apply-changes на этапе
подготовки staging-каталога перед сборкой тайлов.
"""

import json
import math
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

import osmium
import structlog

from publisher.models import CustomRoad
from publisher.osmium_runner import OsmiumRunner

log = structlog.get_logger(__name__)

# Смещение id для кастомных объектов: выше любых реальных id OSM
ID_OFFSET = 10**15
# Максимум точек в геометрии одной дороги для схемы node id
_MAX_POINTS_PER_ROAD = 10**6

_NON_DRIVABLE = {"footway", "path", "steps", "pedestrian", "cycleway"}

_HIGHWAY_BY_ROAD_TYPE = {
    "access_road": "service",
    "winter_road": "track",
    "lpu_internal": "service",
    "connector": "service",
}

_EMPTY_OSC = (
    '<?xml version="1.0" encoding="utf-8"?>\n'
    '<osmChange version="0.6" generator="asu_toir_custom_roads" />'
)


def roads_for_season(roads: list[CustomRoad], season: str) -> list[CustomRoad]:
    """Дороги, попадающие в тайлсет сезона: сезонные + всесезонные."""
    return [r for r in roads if r.season in ("all", season)]


def dist_m(a: tuple[float, float], b: tuple[float, float]) -> float:
    return math.hypot(
        (a[0] - b[0]) * 111320,
        (a[1] - b[1]) * 111320 * math.cos(math.radians(a[0])),
    )


def collect_snap_endpoints(roads: list[CustomRoad]) -> list[tuple[float, float]]:
    endpoints: list[tuple[float, float]] = []
    for road in roads:
        if not road.connect_endpoints:
            continue
        endpoints.append(road.geometry[0])
        endpoints.append(road.geometry[-1])
    return endpoints


def extract_surroundings(
    base_pbf: Path,
    endpoints: list[tuple[float, float]],
    workdir: Path,
    runner: OsmiumRunner,
) -> list[Path]:
    """Вырезает окрестности концов дорог из базовой карты. Возвращает
    пути к малым PBF."""
    margin = 0.01  # ~1 км
    output_names = [f"nearby_{i}.osm.pbf" for i in range(len(endpoints))]
    extracts = [
        {
            "bbox": [lng - margin, lat - margin, lng + margin, lat + margin],
            "output": name,
        }
        for (lat, lng), name in zip(endpoints, output_names, strict=True)
    ]
    config_path = workdir / "extract_config.json"
    config_path.write_text(json.dumps({"extracts": extracts}), encoding="utf-8")
    runner.extract(base_pbf, config_path, workdir)
    return [workdir / name for name in output_names]


class _HighwayNodeCollector(osmium.SimpleHandler):
    """Узлы проезжих highway-way, кастомные id исключаются."""

    def __init__(self) -> None:
        super().__init__()
        self.node_ids: set[int] = set()

    def way(self, w: "osmium.osm.Way") -> None:
        highway = w.tags.get("highway")
        if highway is None or highway in _NON_DRIVABLE or w.id >= ID_OFFSET:
            return
        self.node_ids.update(n.ref for n in w.nodes)


class _NodeLocator(osmium.SimpleHandler):
    def __init__(self, wanted: set[int]) -> None:
        super().__init__()
        self._wanted = wanted
        self.locations: dict[int, tuple[float, float]] = {}

    def node(self, n: "osmium.osm.Node") -> None:
        if n.id in self._wanted:
            self.locations[n.id] = (n.location.lat, n.location.lon)


def build_snap_map(
    nearby_pbfs: list[Path],
    endpoints: list[tuple[float, float]],
    tolerance_m: float,
) -> dict[tuple[float, float], int]:
    """Для каждого конца дороги ближайший узел проезжей сети в допуске."""
    collector = _HighwayNodeCollector()
    for pbf in nearby_pbfs:
        collector.apply_file(str(pbf))
    locator = _NodeLocator(collector.node_ids)
    for pbf in nearby_pbfs:
        locator.apply_file(str(pbf))

    snap_map: dict[tuple[float, float], int] = {}
    for endpoint in endpoints:
        best: tuple[float, int] | None = None
        for node_id, loc in locator.locations.items():
            d = dist_m(endpoint, loc)
            if d <= tolerance_m and (best is None or d < best[0]):
                best = (d, node_id)
        if best is not None:
            snap_map[endpoint] = best[1]
        else:
            log.warning(
                "custom_road_endpoint_not_snapped",
                endpoint=endpoint,
                tolerance_m=tolerance_m,
            )
    return snap_map


def _road_tags(road: CustomRoad) -> dict[str, str]:
    tags = {"highway": _HIGHWAY_BY_ROAD_TYPE[road.road_type], "name": road.name}
    if road.road_type == "winter_road":
        tags["ice_road"] = "yes"
    if road.maxspeed_kmh is not None:
        tags["maxspeed"] = str(road.maxspeed_kmh)
    if road.maxweight_t is not None:
        tags["maxweight"] = str(road.maxweight_t)
    if road.maxheight_m is not None:
        tags["maxheight"] = str(road.maxheight_m)
    return tags


def build_osc(roads: list[CustomRoad], snap_map: dict[tuple[float, float], int]) -> str:
    """Формирует XML OsmChange. Совпадающие координаты разных дорог
    получают общий node id, чтобы касающиеся дороги были связаны графом."""
    root = ET.Element("osmChange", version="0.6", generator="asu_toir_custom_roads")
    create = ET.SubElement(root, "create")

    node_by_coord: dict[tuple[float, float], int] = {}
    nodes_created: set[int] = set()

    for road in roads:
        way_id = ID_OFFSET + road.id
        node_refs: list[int] = []
        for idx, point in enumerate(road.geometry):
            coord = (point[0], point[1])
            is_endpoint = idx in (0, len(road.geometry) - 1)
            if road.connect_endpoints and is_endpoint and coord in snap_map:
                node_refs.append(snap_map[coord])
                continue
            if coord not in node_by_coord:
                node_by_coord[coord] = ID_OFFSET + road.id * _MAX_POINTS_PER_ROAD + idx
            node_id = node_by_coord[coord]
            if node_id not in nodes_created:
                ET.SubElement(
                    create,
                    "node",
                    id=str(node_id),
                    version="1",
                    lat=f"{coord[0]:.7f}",
                    lon=f"{coord[1]:.7f}",
                )
                nodes_created.add(node_id)
            node_refs.append(node_id)

        way = ET.SubElement(create, "way", id=str(way_id), version="1")
        for ref in node_refs:
            ET.SubElement(way, "nd", ref=str(ref))
        for key, value in _road_tags(road).items():
            ET.SubElement(way, "tag", k=key, v=value)

    ET.indent(root)
    return ET.tostring(root, encoding="unicode", xml_declaration=True)


def export_osc(
    roads: list[CustomRoad],
    base_pbf: Path,
    output: Path,
    runner: OsmiumRunner,
    snap_tolerance_m: float = 100.0,
) -> int:
    """Пишет .osc для списка дорог, возвращает число дорог в выгрузке."""
    if not roads:
        output.write_text(_EMPTY_OSC, encoding="utf-8")
        return 0

    endpoints = collect_snap_endpoints(roads)
    snap_map: dict[tuple[float, float], int] = {}
    if endpoints:
        with tempfile.TemporaryDirectory(dir=output.parent) as tmp:
            nearby = extract_surroundings(base_pbf, endpoints, Path(tmp), runner)
            snap_map = build_snap_map(nearby, endpoints, snap_tolerance_m)
        log.info(
            "custom_roads_endpoints_snapped",
            snapped=len(snap_map),
            total=len(endpoints),
        )

    output.write_text(build_osc(roads, snap_map), encoding="utf-8")
    return len(roads)
