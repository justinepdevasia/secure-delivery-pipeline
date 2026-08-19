"""Tests for the HTTP client. urlopen is stubbed — nothing here touches a socket."""

from __future__ import annotations

import io
import urllib.error
from typing import Any

import pytest

from pipeline_tools import httpc


class FakeResponse(io.BytesIO):
    def __init__(self, body: bytes, status: int = 200) -> None:
        super().__init__(body)
        self.status = status

    def __enter__(self) -> FakeResponse:
        return self

    def __exit__(self, *args: object) -> None:
        self.close()


def http_error(code: int) -> urllib.error.HTTPError:
    return urllib.error.HTTPError("u", code, "boom", {}, io.BytesIO(b"detail"))  # type: ignore[arg-type]


@pytest.fixture(autouse=True)
def no_sleep(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(httpc.time, "sleep", lambda _: None)


def test_a_successful_request_returns_the_body(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(httpc.urllib.request, "urlopen", lambda *a, **k: FakeResponse(b'{"a":1}'))
    response = httpc.request("https://example.invalid")
    assert response.status == 200
    assert response.json() == {"a": 1}


def test_a_client_error_is_not_retried(monkeypatch: pytest.MonkeyPatch) -> None:
    calls = {"n": 0}

    def fake(*args: Any, **kwargs: Any) -> Any:
        calls["n"] += 1
        raise http_error(404)

    monkeypatch.setattr(httpc.urllib.request, "urlopen", fake)
    with pytest.raises(httpc.HttpError) as excinfo:
        httpc.request("https://example.invalid", attempts=3)
    assert excinfo.value.status == 404
    assert calls["n"] == 1


def test_a_server_error_is_retried_then_raised(monkeypatch: pytest.MonkeyPatch) -> None:
    calls = {"n": 0}

    def fake(*args: Any, **kwargs: Any) -> Any:
        calls["n"] += 1
        raise http_error(503)

    monkeypatch.setattr(httpc.urllib.request, "urlopen", fake)
    with pytest.raises(httpc.HttpError):
        httpc.request("https://example.invalid", attempts=3)
    assert calls["n"] == 3


def test_a_retry_can_succeed(monkeypatch: pytest.MonkeyPatch) -> None:
    calls = {"n": 0}

    def fake(*args: Any, **kwargs: Any) -> Any:
        calls["n"] += 1
        if calls["n"] < 3:
            raise http_error(500)
        return FakeResponse(b"[]")

    monkeypatch.setattr(httpc.urllib.request, "urlopen", fake)
    assert httpc.request("https://example.invalid", attempts=4).json() == []
    assert calls["n"] == 3


def test_rate_limiting_is_treated_as_retryable(monkeypatch: pytest.MonkeyPatch) -> None:
    calls = {"n": 0}

    def fake(*args: Any, **kwargs: Any) -> Any:
        calls["n"] += 1
        if calls["n"] == 1:
            raise http_error(429)
        return FakeResponse(b"1")

    monkeypatch.setattr(httpc.urllib.request, "urlopen", fake)
    assert httpc.request("https://example.invalid", attempts=2).json() == 1


def test_a_connection_error_is_retried(monkeypatch: pytest.MonkeyPatch) -> None:
    calls = {"n": 0}

    def fake(*args: Any, **kwargs: Any) -> Any:
        calls["n"] += 1
        if calls["n"] < 2:
            raise urllib.error.URLError("no route")
        return FakeResponse(b"true")

    monkeypatch.setattr(httpc.urllib.request, "urlopen", fake)
    assert httpc.request("https://example.invalid", attempts=3).json() is True


def test_get_json_sets_a_bearer_token(monkeypatch: pytest.MonkeyPatch) -> None:
    captured: dict[str, Any] = {}

    def fake_request(url: str, **kwargs: Any) -> httpc.Response:
        captured.update(kwargs)
        return httpc.Response(status=200, body=b"{}")

    monkeypatch.setattr(httpc, "request", fake_request)
    httpc.get_json("https://example.invalid", token="secret")
    assert captured["headers"]["Authorization"] == "Bearer secret"


def test_get_json_omits_the_header_without_a_token(monkeypatch: pytest.MonkeyPatch) -> None:
    captured: dict[str, Any] = {}

    def fake_request(url: str, **kwargs: Any) -> httpc.Response:
        captured.update(kwargs)
        return httpc.Response(status=200, body=b"{}")

    monkeypatch.setattr(httpc, "request", fake_request)
    httpc.get_json("https://example.invalid")
    assert "Authorization" not in captured["headers"]


def test_an_empty_body_decodes_to_none() -> None:
    assert httpc.Response(status=204, body=b"").json() is None


@pytest.mark.parametrize("url", ["file:///etc/passwd", "ftp://example.invalid", "/etc/passwd"])
def test_non_http_schemes_are_refused(url: str) -> None:
    """urllib would otherwise happily read a local file when handed a file:// URL."""
    with pytest.raises(ValueError, match="refusing to request"):
        httpc.request(url)
