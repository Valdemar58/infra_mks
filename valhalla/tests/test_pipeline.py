"""Файловые шаги и оркестрация публикации."""

import json
from pathlib import Path

import pytest

from publisher.models import CustomRoad
from publisher.pipeline import PublishError, PublishPipeline

_MIN_VALHALLA_CONFIG = {
    "service_limits": {
        "truck": {"max_distance": 1.0, "max_matrix_distance": 1.0},
        "auto": {"max_distance": 1.0, "max_matrix_distance": 1.0},
        "max_radius": 200,
    },
    "loki": {"use_connectivity": True},
    "thor": {"costmatrix": {"allow_second_pass": False}},
}


class _FakeRunner:
    """Пишет выходной PBF без вызова osmium."""

    def __init__(self) -> None:
        self.extract_calls: list = []
        self.apply_calls: list = []

    def extract(self, base_pbf: Path, config_path: Path, workdir: Path) -> None:
        self.extract_calls.append((base_pbf, config_path, workdir))
        config = json.loads(config_path.read_text(encoding="utf-8"))
        for extract in config["extracts"]:
            (workdir / extract["output"]).write_bytes(b"")

    def apply_changes(self, base_pbf: Path, osc_path: Path, output_pbf: Path) -> None:
        self.apply_calls.append((base_pbf, osc_path, output_pbf))
        output_pbf.write_bytes(b"merged")


class _FakeTiles:
    def __init__(self, distance: float = 707.0) -> None:
        self.calls: list[str] = []
        self._distance = distance

    def verify_staging_mount(self, season: str) -> None:
        self.calls.append("verify")

    def build(self, season: str) -> None:
        self.calls.append("build")

    def restart_builder(self, season: str) -> None:
        self.calls.append("restart_builder")

    def smoke(self, season: str) -> float:
        self.calls.append("smoke")
        return self._distance

    def drop_builder(self, season: str) -> None:
        self.calls.append("drop_builder")

    def restart_live(self, season: str) -> None:
        self.calls.append("restart_live")


def _road(road_id: int = 1, **overrides) -> CustomRoad:
    payload = {
        "id": road_id,
        "name": "Подъезд",
        "road_type": "access_road",
        "geometry": [(64.0, 69.5), (64.1, 69.6)],
        "connect_endpoints": False,
    }
    payload.update(overrides)
    return CustomRoad(**payload)


def _pipeline(tmp_path: Path, runner=None, tiles=None) -> PublishPipeline:
    return PublishPipeline(
        files_dir=tmp_path,
        tiles=tiles or _FakeTiles(),
        runner=runner or _FakeRunner(),
    )


def _make_live(tmp_path: Path, season: str = "summer") -> Path:
    live = tmp_path / season
    live.mkdir()
    (live / "base_map.osm.pbf").write_bytes(b"base")
    (live / "admins.sqlite").write_bytes(b"admins")
    (live / "default_speeds.json").write_bytes(b"speeds")
    (live / "valhalla.json").write_text(
        json.dumps(_MIN_VALHALLA_CONFIG), encoding="utf-8"
    )
    return live


def test_prepare_builds_staging(tmp_path):
    _make_live(tmp_path)
    runner = _FakeRunner()
    pipeline = _pipeline(tmp_path, runner)

    exported = pipeline.prepare("summer", [_road()])

    staging = tmp_path / "summer_staging"
    assert exported == 1
    assert (staging / "base_map.osm.pbf").read_bytes() == b"merged"
    assert (staging / "admins.sqlite").is_file()
    assert (staging / "default_speeds.json").is_file()
    assert (staging / "changes.osc").is_file()
    assert len(runner.apply_calls) == 1
    config = json.loads((staging / "valhalla.json").read_text(encoding="utf-8"))
    assert config["thor"]["costmatrix"]["allow_second_pass"] is True
    assert config["loki"]["use_connectivity"] is False


def test_prepare_takes_only_season_roads(tmp_path):
    _make_live(tmp_path)
    pipeline = _pipeline(tmp_path)

    exported = pipeline.prepare(
        "summer",
        [_road(1, season="all"), _road(2, season="winter"), _road(3, season="summer")],
    )

    assert exported == 2


def test_prepare_without_roads_skips_apply(tmp_path):
    _make_live(tmp_path)
    runner = _FakeRunner()
    pipeline = _pipeline(tmp_path, runner)

    assert pipeline.prepare("summer", []) == 0
    assert (tmp_path / "summer_staging" / "base_map.osm.pbf").read_bytes() == b"base"
    assert runner.apply_calls == []


def test_prepare_without_base_map_raises(tmp_path):
    pipeline = _pipeline(tmp_path)

    with pytest.raises(PublishError):
        pipeline.prepare("summer", [])


def test_finalize_patches_config_and_smokes(tmp_path):
    staging = tmp_path / "summer_staging"
    staging.mkdir()
    (staging / "valhalla.json").write_text(
        json.dumps(_MIN_VALHALLA_CONFIG), encoding="utf-8"
    )
    tiles = _FakeTiles()
    pipeline = _pipeline(tmp_path, tiles=tiles)

    assert pipeline.finalize("summer") == 707.0
    config = json.loads((staging / "valhalla.json").read_text(encoding="utf-8"))
    assert config["service_limits"]["truck"]["max_matrix_distance"] == 10_000_000.0
    assert tiles.calls == ["restart_builder", "smoke"]


def test_finalize_without_config_raises(tmp_path):
    (tmp_path / "summer_staging").mkdir()
    pipeline = _pipeline(tmp_path)

    with pytest.raises(PublishError):
        pipeline.finalize("summer")


def test_swap_keeps_previous_generation(tmp_path):
    live = _make_live(tmp_path)
    (live / "marker.txt").write_text("old", encoding="utf-8")
    staging = tmp_path / "summer_staging"
    staging.mkdir()
    (staging / "marker.txt").write_text("new", encoding="utf-8")
    pipeline = _pipeline(tmp_path)

    pipeline.swap("summer")

    assert (tmp_path / "summer" / "marker.txt").read_text(encoding="utf-8") == "new"
    assert (tmp_path / "summer_prev" / "marker.txt").read_text(
        encoding="utf-8"
    ) == "old"
    assert not staging.exists()


def test_swap_replaces_older_prev(tmp_path):
    """Хранится только одно поколение для отката, позапрошлое удаляется."""
    live = _make_live(tmp_path)
    (live / "marker.txt").write_text("old", encoding="utf-8")
    prev = tmp_path / "summer_prev"
    prev.mkdir()
    (prev / "marker.txt").write_text("ancient", encoding="utf-8")
    staging = tmp_path / "summer_staging"
    staging.mkdir()
    (staging / "marker.txt").write_text("new", encoding="utf-8")
    pipeline = _pipeline(tmp_path)

    pipeline.swap("summer")

    assert (tmp_path / "summer_prev" / "marker.txt").read_text(
        encoding="utf-8"
    ) == "old"


def test_swap_without_staging_raises(tmp_path):
    _make_live(tmp_path)
    pipeline = _pipeline(tmp_path)

    with pytest.raises(PublishError):
        pipeline.swap("summer")


def test_run_reports_status_sequence(tmp_path):
    _make_live(tmp_path)
    tiles = _FakeTiles()
    pipeline = _pipeline(tmp_path, tiles=tiles)
    reported: list[tuple] = []

    def report(status, *, roads_exported=None, error=None):
        reported.append((status, roads_exported, error))

    pipeline.run("summer", [_road()], report=report)

    assert [r[0] for r in reported] == [
        "preparing",
        "prepared",
        "building",
        "finalized",
        "succeeded",
    ]
    assert reported[1][1] == 1
    assert tiles.calls == [
        "verify",
        "build",
        "restart_builder",
        "smoke",
        "drop_builder",
        "restart_live",
    ]
    assert (tmp_path / "summer_prev").is_dir()


def test_run_checks_mount_before_building(tmp_path):
    """Расхождение HOST_FILES_DIR должно ловиться до часа сборки."""
    _make_live(tmp_path)

    class _BadMount(_FakeTiles):
        def verify_staging_mount(self, season: str) -> None:
            self.calls.append("verify")
            raise RuntimeError("Docker не видит карту")

    tiles = _BadMount()
    pipeline = _pipeline(tmp_path, tiles=tiles)

    with pytest.raises(RuntimeError):
        pipeline.run("summer", [_road()])

    assert "build" not in tiles.calls
