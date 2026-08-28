"""Патч valhalla.json: без него матрицы дальше 400 км не считаются."""

import json

from publisher.valhalla_config import patch_valhalla_config

_MIN_CONFIG = {
    "service_limits": {
        "truck": {
            "max_distance": 1.0,
            "max_matrix_distance": 1.0,
            "max_matrix_location_pairs": 2500,
        },
        "auto": {"max_distance": 1.0, "max_matrix_distance": 1.0},
        "max_radius": 200,
    },
    "loki": {"use_connectivity": True},
    "thor": {"costmatrix": {"allow_second_pass": False}},
}


def _write(tmp_path, config=None):
    path = tmp_path / "valhalla.json"
    path.write_text(json.dumps(config or _MIN_CONFIG), encoding="utf-8")
    return path


def test_patch_raises_limits_and_disables_connectivity(tmp_path):
    path = _write(tmp_path)

    applied = patch_valhalla_config(path)

    config = json.loads(path.read_text(encoding="utf-8"))
    assert config["service_limits"]["truck"]["max_matrix_distance"] == 10_000_000.0
    assert config["service_limits"]["auto"]["max_matrix_distance"] == 10_000_000.0
    assert config["service_limits"]["truck"]["max_matrix_location_pairs"] == 1_000_000
    assert config["service_limits"]["max_radius"] == 1_000
    assert config["loki"]["use_connectivity"] is False
    assert config["thor"]["costmatrix"]["allow_second_pass"] is True
    assert applied["costmatrix_second_pass"] is True


def test_patch_is_idempotent(tmp_path):
    path = _write(tmp_path)

    patch_valhalla_config(path)
    first = path.read_text(encoding="utf-8")
    patch_valhalla_config(path)

    assert path.read_text(encoding="utf-8") == first


def test_patch_reads_utf8_with_bom(tmp_path):
    path = tmp_path / "valhalla.json"
    path.write_text(json.dumps(_MIN_CONFIG), encoding="utf-8-sig")

    patch_valhalla_config(path)

    config = json.loads(path.read_text(encoding="utf-8"))
    assert config["loki"]["use_connectivity"] is False
