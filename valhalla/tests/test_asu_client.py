"""Контракт с API АСУ: пути, параметры, авторизация, разбор ответов."""

import json

import httpx
import pytest

from publisher.asu_client import AsuApiError, AsuClient

_ROAD_JSON = {
    "id": 5,
    "name": "Перемычка",
    "road_type": "connector",
    "geometry": [[64.03618, 69.53926], [64.037, 69.54]],
    "maxspeed_kmh": 40,
    "maxweight_t": None,
    "maxheight_m": None,
    "season": "all",
    "active": True,
    "connect_endpoints": True,
    "comment": None,
    # Поля, которые publisher не использует и должен молча игнорировать
    "created_by": "ivanov",
    "created_at": "2026-08-15T12:00:00",
    "updated_by": None,
    "updated_at": None,
    "is_deleted": False,
}

_REQUEST_JSON = {
    "id": 12,
    "season": "summer",
    "status": "requested",
    "requested_by": "ivanov",
    "requested_at": "2026-08-15T12:00:00",
    "started_at": None,
    "finished_at": None,
    "roads_exported": None,
    "error": None,
}


def _client(handler) -> AsuClient:
    client = AsuClient("http://api:8000", "secret-token")
    client._client = httpx.Client(
        base_url="http://api:8000",
        transport=httpx.MockTransport(handler),
        headers={"Authorization": "ApiKey secret-token"},
    )
    return client


def test_pending_requests_filters_and_sorts():
    seen: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        second = dict(_REQUEST_JSON, id=3)
        return httpx.Response(200, json=[_REQUEST_JSON, second])

    with _client(handler) as client:
        requests = client.pending_requests()

    assert seen[0].url.path == "/v1/custom-roads/publish-requests"
    assert seen[0].url.params["status_filter"] == "requested"
    assert seen[0].headers["Authorization"] == "ApiKey secret-token"
    # Старые заявки обрабатываются первыми
    assert [r.id for r in requests] == [3, 12]


def test_active_roads_asks_only_for_live_roads():
    seen: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        return httpx.Response(200, json=[_ROAD_JSON])

    with _client(handler) as client:
        roads = client.active_roads()

    assert seen[0].url.path == "/v1/custom-roads"
    assert seen[0].url.params["active"] == "true"
    assert seen[0].url.params["is_deleted"] == "false"
    assert roads[0].geometry == [(64.03618, 69.53926), (64.037, 69.54)]
    assert roads[0].connect_endpoints is True


def test_mark_status_sends_only_filled_fields():
    bodies: list[dict] = []

    def handler(request: httpx.Request) -> httpx.Response:
        bodies.append(json.loads(request.content))
        return httpx.Response(200, json=dict(_REQUEST_JSON, status="building"))

    with _client(handler) as client:
        client.mark_status(12, "building")
        client.mark_status(12, "prepared", roads_exported=7)

    assert bodies[0] == {"status": "building"}
    assert bodies[1] == {"status": "prepared", "roads_exported": 7}


def test_mark_status_truncates_long_error():
    bodies: list[dict] = []

    def handler(request: httpx.Request) -> httpx.Response:
        bodies.append(json.loads(request.content))
        return httpx.Response(200, json=dict(_REQUEST_JSON, status="failed"))

    with _client(handler) as client:
        client.mark_status(12, "failed", error="x" * 5000)

    assert bodies[0]["error"] == "x" * 1000


def test_error_response_raises():
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(409, json={"error_code": "PUBLISH_INVALID_STATUS"})

    with _client(handler) as client, pytest.raises(AsuApiError):
        client.mark_status(12, "succeeded")


def test_network_failure_raises():
    def handler(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("connection refused")

    with _client(handler) as client, pytest.raises(AsuApiError):
        client.pending_requests()
