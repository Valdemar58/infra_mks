"""Обработчик очереди заявок на публикацию.

Опрашивает API АСУ и на каждую заявку в статусе requested прогоняет
полный цикл публикации. Заявки одного сезона не пересекаются: АСУ не дает
создать вторую, пока активна первая.
"""

import time

import structlog

from publisher.asu_client import AsuClient
from publisher.osmium_runner import LocalOsmiumRunner
from publisher.pipeline import PublishPipeline
from publisher.settings import Settings
from publisher.tiles import DockerTileService

log = structlog.get_logger(__name__)


def build_pipeline(config: Settings) -> PublishPipeline:
    tiles = DockerTileService(
        host_files_dir=config.host_files_dir,
        image=config.valhalla_image,
        network=config.docker_network,
        live_container_prefix=config.live_container_prefix,
        build_threads=config.build_threads,
        build_timeout_s=config.build_timeout_s,
    )
    return PublishPipeline(
        files_dir=config.files_dir,
        tiles=tiles,
        runner=LocalOsmiumRunner(),
        snap_tolerance_m=config.snap_tolerance_m,
    )


def process_pending(client: AsuClient, pipeline: PublishPipeline) -> int:
    """Обрабатывает все ожидающие заявки, возвращает их число."""
    requests = client.pending_requests()
    for request in requests:
        log.info("publish_started", request_id=request.id, season=request.season)

        def report(status, *, roads_exported=None, error=None, _id=request.id) -> None:
            client.mark_status(_id, status, roads_exported=roads_exported, error=error)

        try:
            roads = client.active_roads()
            pipeline.run(request.season, roads, report=report)
            log.info("publish_succeeded", request_id=request.id)
        except Exception as exc:
            log.error("publish_failed", request_id=request.id, error=str(exc))
            try:
                client.mark_status(request.id, "failed", error=str(exc))
            except Exception as mark_exc:
                log.error(
                    "publish_mark_failed", request_id=request.id, error=str(mark_exc)
                )
    return len(requests)


def run_forever(config: Settings) -> None:
    pipeline = build_pipeline(config)
    log.info(
        "publisher_started", api=config.asu_api_url, interval=config.poll_interval_s
    )
    while True:
        try:
            with AsuClient(config.asu_api_url, config.asu_api_token) as client:
                process_pending(client, pipeline)
        except Exception as exc:
            # Недоступный API не должен ронять сервис: следующая итерация
            log.error("poll_failed", error=str(exc))
        time.sleep(config.poll_interval_s)
