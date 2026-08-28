"""Публикация кастомных дорог: от заявки до перезапуска живого сервиса.

Последовательность: staging-копия карты -> экспорт .osc -> вливание в
PBF -> сборка тайлов -> патч конфига и смоук -> swap каталогов ->
перезапуск живого контейнера. Живой сервис отвечает на запросы все время
сборки, простой только на секунды перезапуска.

Предыдущее поколение тайлов остается в <сезон>_prev: откат это обмен
каталогов местами и перезапуск.
"""

import shutil
from pathlib import Path
from typing import Protocol

import structlog

from publisher.models import CustomRoad, PublishStatus
from publisher.osc_export import export_osc, roads_for_season
from publisher.osmium_runner import OsmiumRunner
from publisher.tiles import TileService
from publisher.valhalla_config import patch_valhalla_config

log = structlog.get_logger(__name__)

_COPY_FILES = ("base_map.osm.pbf", "admins.sqlite", "timezones.sqlite", "valhalla.json")


class PublishError(RuntimeError):
    pass


class StatusReporter(Protocol):
    def __call__(
        self,
        status: PublishStatus,
        *,
        roads_exported: int | None = None,
        error: str | None = None,
    ) -> None: ...


def _noop_reporter(
    status: PublishStatus,
    *,
    roads_exported: int | None = None,
    error: str | None = None,
) -> None:
    return None


class PublishPipeline:
    def __init__(
        self,
        files_dir: Path,
        tiles: TileService,
        runner: OsmiumRunner,
        snap_tolerance_m: float = 100.0,
    ):
        self.files_dir = files_dir
        self.tiles = tiles
        self.runner = runner
        self.snap_tolerance_m = snap_tolerance_m

    def run(
        self,
        season: str,
        roads: list[CustomRoad],
        report: StatusReporter = _noop_reporter,
    ) -> None:
        """Полный цикл публикации сезона. Исключения не глушит."""
        report("preparing")
        exported = self.prepare(season, roads)
        report("prepared", roads_exported=exported)

        report("building")
        self.tiles.verify_staging_mount(season)
        self.tiles.build(season)

        distance = self.finalize(season)
        log.info("publish_smoke_ok", season=season, distance_km=distance)
        report("finalized")

        self.swap(season)
        self.tiles.drop_builder(season)
        self.tiles.restart_live(season)
        report("succeeded")

    def prepare(self, season: str, roads: list[CustomRoad]) -> int:
        """Готовит staging-каталог, возвращает число выгруженных дорог."""
        live = self.files_dir / season
        staging = self.files_dir / f"{season}_staging"
        base_pbf = live / "base_map.osm.pbf"
        if not base_pbf.is_file():
            raise PublishError(f"Нет базовой карты {base_pbf}")

        if staging.exists():
            shutil.rmtree(staging)
        staging.mkdir(parents=True)
        for name in _COPY_FILES:
            src = live / name
            if src.is_file():
                shutil.copy2(src, staging / name)

        # Конфиг копируется уже пропатченным, но патчим повторно, чтобы
        # staging-сборка сразу поднялась с нужными лимитами
        staging_config = staging / "valhalla.json"
        if staging_config.is_file():
            patch_valhalla_config(staging_config)

        season_roads = roads_for_season(roads, season)
        exported = export_osc(
            season_roads,
            base_pbf=staging / "base_map.osm.pbf",
            output=staging / "changes.osc",
            runner=self.runner,
            snap_tolerance_m=self.snap_tolerance_m,
        )
        if exported:
            final_pbf = staging / "base_map_final.osm.pbf"
            self.runner.apply_changes(
                staging / "base_map.osm.pbf", staging / "changes.osc", final_pbf
            )
            final_pbf.replace(staging / "base_map.osm.pbf")
        log.info("publish_prepared", season=season, roads=exported)
        return exported

    def finalize(self, season: str) -> float:
        """Патч конфига собранного тайлсета и смоук-проверка."""
        staging_config = self.files_dir / f"{season}_staging" / "valhalla.json"
        if not staging_config.is_file():
            raise PublishError(f"Сборка не оставила конфиг {staging_config}")
        applied = patch_valhalla_config(staging_config)
        log.info("publish_config_patched", season=season, **applied)
        self.tiles.restart_builder(season)
        return self.tiles.smoke(season)

    def swap(self, season: str) -> None:
        live = self.files_dir / season
        staging = self.files_dir / f"{season}_staging"
        prev = self.files_dir / f"{season}_prev"
        if not staging.is_dir():
            raise PublishError(f"Нет staging-каталога {staging}")
        if prev.exists():
            shutil.rmtree(prev)
        live.rename(prev)
        staging.rename(live)
        log.info("publish_swapped", season=season, prev=str(prev))
