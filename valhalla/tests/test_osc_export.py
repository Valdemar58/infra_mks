"""Юнит-тесты чистых функций экспорта кастомных дорог в .osc."""

import xml.etree.ElementTree as ET

from publisher.models import CustomRoad, OsmWayOverride
from publisher.osc_export import (
    ID_OFFSET,
    OsmWay,
    build_osc,
    collect_snap_endpoints,
    override_tags,
    roads_for_season,
)

_WAY = OsmWay(
    id=4242, version=7, nodes=[1, 2, 3], tags={"highway": "track", "name": "Зимник"}
)


def test_winter_road_is_closed_in_summer_only():
    override = OsmWayOverride(way_id=4242, season="winter_only", maxweight_t=30)

    summer = override_tags(_WAY, override, "summer")
    winter = override_tags(_WAY, override, "winter")

    assert summer["motor_vehicle"] == "no"
    assert "motor_vehicle" not in winter
    assert winter["ice_road"] == "yes"
    assert summer["maxweight"] == winter["maxweight"] == "30.0"
    assert summer["highway"] == "track"


def test_closed_road_is_closed_in_both_seasons():
    override = OsmWayOverride(way_id=4242, season="closed")

    assert override_tags(_WAY, override, "winter")["motor_vehicle"] == "no"


def test_modified_way_keeps_its_nodes_and_gets_new_tags():
    tags = override_tags(
        _WAY, OsmWayOverride(way_id=4242, maxwidth_m=2.5, maxlength_m=12), "summer"
    )
    modified = OsmWay(id=4242, version=8, nodes=_WAY.nodes, tags=tags)

    root = ET.fromstring(build_osc([], {}, [modified]))

    [way] = root.findall("./modify/way")
    assert (way.get("id"), way.get("version")) == ("4242", "8")
    assert [nd.get("ref") for nd in way.findall("nd")] == ["1", "2", "3"]
    way_tags = {t.get("k"): t.get("v") for t in way.findall("tag")}
    assert way_tags["maxwidth"] == "2.5"
    assert way_tags["maxlength"] == "12.0"


def _road(road_id: int, **overrides) -> CustomRoad:
    payload = {
        "id": road_id,
        "name": f"Дорога {road_id}",
        "road_type": "access_road",
        "geometry": [(64.0, 69.5), (64.001, 69.501), (64.002, 69.502)],
    }
    payload.update(overrides)
    return CustomRoad(**payload)


def test_roads_for_season_includes_all_season_roads():
    roads = [
        _road(1, season="all"),
        _road(2, season="summer"),
        _road(3, season="winter"),
    ]

    assert [r.id for r in roads_for_season(roads, "summer")] == [1, 2]
    assert [r.id for r in roads_for_season(roads, "winter")] == [1, 3]


def test_collect_snap_endpoints_only_for_connectable_roads():
    roads = [
        _road(1),
        _road(2, connect_endpoints=False),
    ]

    endpoints = collect_snap_endpoints(roads)

    assert endpoints == [(64.0, 69.5), (64.002, 69.502)]


def test_build_osc_ids_offset_and_snap_reuse():
    road = _road(1)
    # Первый конец привязан к существующему узлу OSM, второй - нет
    snap_map = {(64.0, 69.5): 12696575329}

    root = ET.fromstring(build_osc([road], snap_map))

    nodes = root.findall("./create/node")
    ways = root.findall("./create/way")
    assert len(ways) == 1
    assert int(ways[0].get("id")) == ID_OFFSET + 1
    # Привязанный конец не создает нового узла: 3 точки - 1 привязка = 2 узла
    assert len(nodes) == 2
    assert all(int(n.get("id")) >= ID_OFFSET for n in nodes)

    refs = [int(nd.get("ref")) for nd in ways[0].findall("nd")]
    assert refs[0] == 12696575329
    assert all(ref >= ID_OFFSET for ref in refs[1:])


def test_build_osc_shared_coordinate_gets_shared_node():
    # Конец первой дороги совпадает с началом второй - общий узел графа
    road_a = _road(1, geometry=[(64.0, 69.5), (64.001, 69.501)])
    road_b = _road(2, geometry=[(64.001, 69.501), (64.002, 69.502)])

    root = ET.fromstring(build_osc([road_a, road_b], snap_map={}))

    ways = {int(w.get("id")): w for w in root.findall("./create/way")}
    refs_a = [int(nd.get("ref")) for nd in ways[ID_OFFSET + 1].findall("nd")]
    refs_b = [int(nd.get("ref")) for nd in ways[ID_OFFSET + 2].findall("nd")]
    assert refs_a[-1] == refs_b[0]
    # Общий узел создан только один раз
    node_ids = [int(n.get("id")) for n in root.findall("./create/node")]
    assert len(node_ids) == len(set(node_ids)) == 3


def test_build_osc_tags_by_road_type_and_limits():
    road = _road(
        1,
        road_type="winter_road",
        maxspeed_kmh=40,
        maxweight_t=38.5,
        maxheight_m=4.5,
    )

    root = ET.fromstring(build_osc([road], snap_map={}))

    tags = {t.get("k"): t.get("v") for t in root.findall("./create/way/tag")}
    assert tags["highway"] == "track"
    assert tags["ice_road"] == "yes"
    assert tags["maxspeed"] == "40"
    assert tags["maxweight"] == "38.5"
    assert tags["maxheight"] == "4.5"
