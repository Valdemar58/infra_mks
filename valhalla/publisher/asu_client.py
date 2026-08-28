"""Клиент API АСУ: заявки на публикацию и кастомные дороги."""

import httpx

from publisher.models import CustomRoad, PublishRequest, PublishStatus

_ROADS_PATH = "/v1/custom-roads"
_REQUESTS_PATH = "/v1/custom-roads/publish-requests"


class AsuApiError(RuntimeError):
    pass


class AsuClient:
    def __init__(self, base_url: str, token: str, timeout: float = 30.0):
        self._client = httpx.Client(
            base_url=base_url.rstrip("/"),
            timeout=httpx.Timeout(timeout),
            headers={"Authorization": f"ApiKey {token}"},
            follow_redirects=True,
        )

    def close(self) -> None:
        self._client.close()

    def __enter__(self) -> "AsuClient":
        return self

    def __exit__(self, *exc_info: object) -> None:
        self.close()

    def _request(self, method: str, path: str, **kwargs) -> httpx.Response:
        try:
            response = self._client.request(method, path, **kwargs)
        except httpx.HTTPError as exc:
            raise AsuApiError(f"{method} {path}: {exc}") from exc
        if response.is_error:
            raise AsuApiError(
                f"{method} {path}: {response.status_code} {response.text[:300]}"
            )
        return response

    def pending_requests(self, limit: int = 20) -> list[PublishRequest]:
        """Заявки, ожидающие обработки, старые первыми."""
        response = self._request(
            "GET",
            _REQUESTS_PATH,
            params={"status_filter": "requested", "limit": limit},
        )
        requests = [PublishRequest.model_validate(item) for item in response.json()]
        return sorted(requests, key=lambda r: r.id)

    def active_roads(self) -> list[CustomRoad]:
        response = self._request(
            "GET",
            _ROADS_PATH,
            params={"active": True, "is_deleted": False},
        )
        return [CustomRoad.model_validate(item) for item in response.json()]

    def mark_status(
        self,
        request_id: int,
        status: PublishStatus,
        roads_exported: int | None = None,
        error: str | None = None,
    ) -> PublishRequest:
        payload: dict[str, object] = {"status": status}
        if roads_exported is not None:
            payload["roads_exported"] = roads_exported
        if error is not None:
            # Поле в БД без ограничения длины, но простыни стектрейсов там не нужны
            payload["error"] = error[:1000]
        response = self._request(
            "PATCH", f"{_REQUESTS_PATH}/{request_id}", json=payload
        )
        return PublishRequest.model_validate(response.json())
