"""Модели обмена с API АСУ.

Зеркало моделей домена custom_roads. Читаются только те поля, которые
нужны для экспорта в .osc, остальное игнорируется.
"""

import datetime as dt
from typing import Literal

from pydantic import BaseModel, ConfigDict

RoadType = Literal["access_road", "winter_road", "lpu_internal", "connector"]
RoadSeason = Literal["all", "summer", "winter"]
PublishSeason = Literal["summer", "winter"]
OverrideSeason = Literal["all", "winter_only", "closed"]

PublishStatus = Literal[
    "requested",
    "preparing",
    "prepared",
    "building",
    "finalized",
    "succeeded",
    "failed",
]


class CustomRoad(BaseModel):
    model_config = ConfigDict(extra="ignore")

    id: int
    name: str
    road_type: RoadType
    geometry: list[tuple[float, float]]
    maxspeed_kmh: int | None = None
    maxweight_t: float | None = None
    maxheight_m: float | None = None
    maxwidth_m: float | None = None
    maxlength_m: float | None = None
    season: RoadSeason = "all"
    connect_endpoints: bool = True


class OsmWayOverride(BaseModel):
    """Свойства существующей дороги OSM, которые публикация заменяет.

    winter_only закрывает дорогу в летнем графе, closed в обоих.
    """

    model_config = ConfigDict(extra="ignore")

    way_id: int
    name: str = ""
    season: OverrideSeason = "all"
    maxspeed_kmh: int | None = None
    maxweight_t: float | None = None
    maxheight_m: float | None = None
    maxwidth_m: float | None = None
    maxlength_m: float | None = None


class PublishRequest(BaseModel):
    model_config = ConfigDict(extra="ignore")

    id: int
    season: PublishSeason
    status: PublishStatus
    requested_by: str
    requested_at: dt.datetime
    roads_exported: int | None = None
    error: str | None = None
