"""Сборка тайлов одноразовым контейнером и управление живым сервисом.

Publisher сам тайлы не собирает: он поднимает контейнер valhalla-scripted
на staging-каталоге, дожидается ответа на /status и общается с ним по
сети docker, а не через порты хоста.

Каталог монтируется в builder по пути **на хосте**: docker-демон живет
вне контейнера publisher и путь внутри publisher ему неизвестен. Отсюда
пара FILES_DIR и HOST_FILES_DIR в настройках.
"""

import time
from pathlib import Path
from typing import Protocol

import docker
import httpx
import structlog
from docker.errors import DockerException, NotFound

log = structlog.get_logger(__name__)

# Смоук-пара Москва - Санкт-Петербург: дальше 400 км, проверяет и тайлы,
# и примененный патч лимитов
SMOKE_FROM = (55.7558, 37.6173)
SMOKE_TO = (59.9343, 30.3351)

# Признак упавшего valhalla_build_tiles: тайлы частичные, сервис поднимется
# с пустым графом и будет отвечать "No suitable edges near location"
_BUILD_FAILED_MARKER = "failed; not hashing"

_STATUS_POLL_S = 15


class TileError(RuntimeError):
    pass


class TileService(Protocol):
    def verify_staging_mount(self, season: str) -> None: ...

    def build(self, season: str) -> None: ...

    def restart_builder(self, season: str) -> None: ...

    def smoke(self, season: str) -> float: ...

    def drop_builder(self, season: str) -> None: ...

    def restart_live(self, season: str) -> None: ...


class DockerTileService:
    def __init__(
        self,
        host_files_dir: Path,
        image: str,
        network: str,
        live_container_prefix: str,
        build_threads: int = 8,
        build_timeout_s: int = 4 * 60 * 60,
    ):
        self._host_files_dir = host_files_dir
        self._image = image
        self._network = network
        self._prefix = live_container_prefix
        self._build_threads = build_threads
        self._build_timeout_s = build_timeout_s
        self._client = docker.from_env()

    def _builder_name(self, season: str) -> str:
        return f"{self._prefix}_{season}_builder"

    def _builder_url(self, season: str) -> str:
        return f"http://{self._builder_name(season)}:8002"

    def _staging_path(self, season: str) -> str:
        """Путь staging-каталога на хосте, в форме для docker-демона."""
        return (self._host_files_dir / f"{season}_staging").as_posix()

    def verify_staging_mount(self, season: str) -> None:
        """Проверяет, что docker-демон видит карту по хостовому пути.

        Расхождение FILES_DIR и HOST_FILES_DIR дает builder'у пустой
        каталог: сборка отработает час и поднимет пустой граф. Дешевле
        убедиться заранее одноразовым контейнером.
        """
        host_staging = self._staging_path(season)
        try:
            self._client.containers.run(
                self._image,
                entrypoint="/bin/sh",
                command=["-c", "test -s /custom_files/base_map.osm.pbf"],
                volumes={host_staging: {"bind": "/custom_files", "mode": "ro"}},
                remove=True,
            )
        except DockerException as exc:
            raise TileError(
                f"Docker не видит карту в {host_staging}. Проверьте HOST_FILES_DIR "
                f"и монтирование каталога в publisher: {exc}"
            ) from exc

    def build(self, season: str) -> None:
        """Поднимает builder на staging-каталоге и ждет готовности графа."""
        name = self._builder_name(season)
        self.drop_builder(season)
        host_staging = self._staging_path(season)
        log.info("tiles_build_started", season=season, staging=host_staging)
        self._client.containers.run(
            self._image,
            detach=True,
            name=name,
            network=self._network,
            volumes={host_staging: {"bind": "/custom_files", "mode": "rw"}},
            environment={
                "serve_tiles": "True",
                "build_tar": "True",
                "build_admins": "True",
                "build_time_zones": "True",
                "build_elevation": "False",
                "server_threads": str(self._build_threads),
            },
        )
        self._wait_ready(season, timeout_s=self._build_timeout_s, watch_build=True)
        log.info("tiles_build_finished", season=season)

    def restart_builder(self, season: str) -> None:
        """Перезапуск после патча конфига, чтобы лимиты вступили в силу."""
        self._container(self._builder_name(season)).restart()
        self._wait_ready(season, timeout_s=600, watch_build=False)

    def smoke(self, season: str) -> float:
        body = {
            "sources": [{"lat": SMOKE_FROM[0], "lon": SMOKE_FROM[1]}],
            "targets": [{"lat": SMOKE_TO[0], "lon": SMOKE_TO[1]}],
            "costing": "truck",
            "units": "kilometers",
        }
        try:
            response = httpx.post(
                f"{self._builder_url(season)}/sources_to_targets",
                json=body,
                timeout=120.0,
            )
            response.raise_for_status()
            distance = response.json()["sources_to_targets"][0][0]["distance"]
        except (httpx.HTTPError, KeyError, IndexError, TypeError) as exc:
            raise TileError(f"Смоук-проверка не прошла: {exc}") from exc
        if distance is None or distance <= 0:
            raise TileError(
                f"Смоук-проверка не прошла: расстояние Москва-СПб = {distance}"
            )
        return float(distance)

    def drop_builder(self, season: str) -> None:
        try:
            self._client.containers.get(self._builder_name(season)).remove(force=True)
        except NotFound:
            return
        except DockerException as exc:
            log.warning("builder_remove_failed", season=season, error=str(exc))

    def restart_live(self, season: str) -> None:
        name = f"{self._prefix}_{season}"
        log.info("live_restart", container=name)
        self._container(name).restart()

    def _container(self, name: str):
        try:
            return self._client.containers.get(name)
        except NotFound as exc:
            raise TileError(f"Контейнер {name} не найден") from exc

    def _wait_ready(self, season: str, timeout_s: int, watch_build: bool) -> None:
        name = self._builder_name(season)
        url = f"{self._builder_url(season)}/status"
        deadline = time.monotonic() + timeout_s
        while time.monotonic() < deadline:
            try:
                if httpx.get(url, timeout=10.0).status_code == 200:
                    return
            except httpx.HTTPError:
                pass
            container = self._container(name)
            container.reload()
            if container.status != "running":
                tail = container.logs(tail=50).decode("utf-8", errors="replace")
                raise TileError(f"Сборка тайлов упала ({name}):\n{tail}")
            if watch_build:
                logs = container.logs().decode("utf-8", errors="replace")
                if _BUILD_FAILED_MARKER in logs:
                    raise TileError(
                        f"valhalla_build_tiles упал, тайлы частичные ({name}). "
                        "Логи: docker logs " + name
                    )
            time.sleep(_STATUS_POLL_S)
        raise TileError(f"Сборка тайлов не уложилась в {timeout_s} с ({name})")
