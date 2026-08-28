"""Конфигурация publisher, единственная точка чтения переменных среды."""

from functools import lru_cache
from pathlib import Path

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    asu_api_url: str = Field(
        default="http://asu_toir_api:8000",
        validation_alias="ASU_API_URL",
        description="Адрес API АСУ.",
    )
    asu_api_token: str = Field(
        default="",
        validation_alias="ASU_API_TOKEN",
        description="M2M токен с правами custom_roads view и edit.",
    )
    files_dir: Path = Field(
        default=Path("/custom_files"),
        validation_alias="FILES_DIR",
        description="Каталог тайлсетов внутри контейнера publisher.",
    )
    host_files_dir: Path = Field(
        default=Path("/opt/valhalla/custom_files"),
        validation_alias="HOST_FILES_DIR",
        description="Тот же каталог на хосте, для монтирования в builder.",
    )
    valhalla_image: str = Field(
        default="ghcr.io/valhalla/valhalla-scripted:3.8.3",
        validation_alias="VALHALLA_IMAGE",
        description="Образ, которым собираются тайлы.",
    )
    docker_network: str = Field(
        default="app-network",
        validation_alias="DOCKER_NETWORK",
        description="Сеть для builder-контейнера, publisher ходит в него по имени.",
    )
    live_container_prefix: str = Field(
        default="infra_valhalla",
        validation_alias="LIVE_CONTAINER_PREFIX",
        description="Префикс имен живых контейнеров, к нему добавляется сезон.",
    )
    build_threads: int = Field(
        default=8,
        ge=1,
        validation_alias="BUILD_THREADS",
        description="Потоки сборки тайлов. При OOM снизить до 4.",
    )
    snap_tolerance_m: float = Field(
        default=100.0,
        gt=0,
        validation_alias="SNAP_TOLERANCE_M",
        description="Максимальное расстояние привязки конца дороги к узлу OSM.",
    )
    poll_interval_s: int = Field(
        default=30,
        ge=1,
        validation_alias="POLL_INTERVAL_S",
        description="Интервал опроса заявок на публикацию.",
    )
    build_timeout_s: int = Field(
        default=4 * 60 * 60,
        ge=60,
        validation_alias="BUILD_TIMEOUT_S",
        description="Потолок ожидания сборки тайлов.",
    )

    def live_container(self, season: str) -> str:
        return f"{self.live_container_prefix}_{season}"

    def builder_container(self, season: str) -> str:
        return f"{self.live_container_prefix}_{season}_builder"


@lru_cache
def settings() -> Settings:
    return Settings()
