"""CLI publisher.

python -m publisher.cli worker                  постоянная обработка заявок
python -m publisher.cli publish --season summer разовая публикация
python -m publisher.cli patch-config <path>     ручной патч valhalla.json
"""

import argparse
import logging
import pathlib
import sys

import structlog

from publisher.asu_client import AsuClient
from publisher.settings import settings
from publisher.valhalla_config import patch_valhalla_config
from publisher.worker import build_pipeline, run_forever


def _setup_logging() -> None:
    logging.basicConfig(format="%(message)s", stream=sys.stdout, level=logging.INFO)
    structlog.configure(
        processors=[
            structlog.processors.add_log_level,
            structlog.processors.TimeStamper(fmt="iso"),
            structlog.dev.ConsoleRenderer(colors=False),
        ]
    )


def _publish(season: str) -> None:
    config = settings()
    pipeline = build_pipeline(config)
    with AsuClient(config.asu_api_url, config.asu_api_token) as client:
        roads = client.active_roads()
    pipeline.run(season, roads)
    print(
        f"Готово. Предыдущее поколение тайлов в {config.files_dir / f'{season}_prev'}"
    )


def _patch(config_path: pathlib.Path) -> None:
    applied = patch_valhalla_config(config_path)
    print(
        "Патч применен: "
        + ", ".join(f"{key}={value}" for key, value in applied.items())
    )


def main() -> None:
    parser = argparse.ArgumentParser(description="Publisher кастомных дорог Valhalla")
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("worker", help="Постоянная обработка заявок на публикацию")

    publish = sub.add_parser("publish", help="Разовая публикация сезона")
    publish.add_argument("--season", choices=["summer", "winter"], default="summer")

    patch = sub.add_parser("patch-config", help="Патч valhalla.json")
    patch.add_argument("config_path", type=pathlib.Path)

    args = parser.parse_args()
    _setup_logging()

    if args.command == "worker":
        run_forever(settings())
    elif args.command == "publish":
        _publish(args.season)
    else:
        _patch(args.config_path)


if __name__ == "__main__":
    main()
