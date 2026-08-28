import subprocess
from pathlib import Path
from typing import Protocol


class OsmiumRunner(Protocol):
    """Запуск osmium-tool: extract окрестностей и вливание .osc в карту."""

    def extract(self, base_pbf: Path, config_path: Path, workdir: Path) -> None: ...

    def apply_changes(
        self, base_pbf: Path, osc_path: Path, output_pbf: Path
    ) -> None: ...


class LocalOsmiumRunner:
    """Osmium-tool установлен в образе publisher."""

    def _run(self, args: list[str], cwd: Path | None = None) -> None:
        proc = subprocess.run(args, cwd=cwd, capture_output=True, text=True)
        if proc.returncode != 0:
            raise RuntimeError(f"{args[0]} {args[1]}: {proc.stderr.strip()[-500:]}")

    def extract(self, base_pbf: Path, config_path: Path, workdir: Path) -> None:
        # cwd задает workdir, чтобы относительные output из конфига
        # ложились рядом, поэтому пути аргументов должны быть абсолютными
        self._run(
            [
                "osmium",
                "extract",
                "--config",
                str(config_path.resolve()),
                "--overwrite",
                str(base_pbf.resolve()),
            ],
            cwd=workdir,
        )

    def apply_changes(self, base_pbf: Path, osc_path: Path, output_pbf: Path) -> None:
        self._run(
            [
                "osmium",
                "apply-changes",
                str(base_pbf.resolve()),
                str(osc_path.resolve()),
                "-o",
                str(output_pbf.resolve()),
                "--overwrite",
            ]
        )
