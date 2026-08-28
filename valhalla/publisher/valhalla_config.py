"""Обязательный патч valhalla.json после каждой сборки тайлов.

Дефолты сгенерированного конфига фатальны для нашего использования:
- max_matrix_distance 400 км режет любые матрицы через всю Россию;
- loki.use_connectivity отклоняет весь матричный запрос, если хоть одна
  точка прицепилась к изолированному фрагменту дорог, вместо null для
  недостижимых пар;
- max_radius 200 м ограничивает клиентский параметр radius привязки;
- costmatrix без второго прохода не проходит шлагбаумы и участки
  destination-only, точки за ними дают null в матрице, хотя /route
  строит маршрут.
"""

import json
from pathlib import Path


def patch_valhalla_config(config_path: Path) -> dict[str, object]:
    """Правит valhalla.json на месте, возвращает примененные значения."""
    cfg = json.loads(config_path.read_text(encoding="utf-8-sig"))
    for costing in ("truck", "auto"):
        limits = cfg["service_limits"][costing]
        limits["max_distance"] = 10_000_000.0
        limits["max_matrix_distance"] = 10_000_000.0
        if "max_matrix_location_pairs" in limits:
            limits["max_matrix_location_pairs"] = 1_000_000
        if "max_matrix_locations" in limits:
            limits["max_matrix_locations"] = 1_000
    if "max_radius" in cfg["service_limits"]:
        cfg["service_limits"]["max_radius"] = 1_000
    cfg["loki"]["use_connectivity"] = False
    cfg["thor"]["costmatrix"]["allow_second_pass"] = True
    config_path.write_text(json.dumps(cfg, indent=2), encoding="utf-8")

    return {
        "max_matrix_distance": cfg["service_limits"]["truck"]["max_matrix_distance"],
        "max_radius": cfg["service_limits"].get("max_radius"),
        "use_connectivity": cfg["loki"]["use_connectivity"],
        "costmatrix_second_pass": cfg["thor"]["costmatrix"]["allow_second_pass"],
    }
