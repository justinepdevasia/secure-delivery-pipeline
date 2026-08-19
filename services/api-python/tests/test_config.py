"""Configuration tests. The boto3 client is stubbed — no network, no emulator.

The emulator-backed variant of this code path runs as a separate job in
``ci-python.yml``; see ``tests/test_secrets_integration.py``.
"""

from __future__ import annotations

import json
from typing import Any

import pytest
from botocore.exceptions import ClientError

from api_python import config


class _FakeClient:
    def __init__(self, payload: Any = None, error: Exception | None = None) -> None:
        self._payload = payload
        self._error = error
        self.calls: list[str] = []

    def get_secret_value(self, SecretId: str) -> dict[str, Any]:  # noqa: N803
        self.calls.append(SecretId)
        if self._error is not None:
            raise self._error
        return self._payload if isinstance(self._payload, dict) else {}


def _patch_client(monkeypatch: pytest.MonkeyPatch, fake: _FakeClient) -> None:
    monkeypatch.setattr(config, "secrets_client", lambda: fake)


def test_load_secret_decodes_json(monkeypatch: pytest.MonkeyPatch) -> None:
    fake = _FakeClient({"SecretString": json.dumps({"environment": "emulated"})})
    _patch_client(monkeypatch, fake)
    assert config.load_secret("sid") == {"environment": "emulated"}
    assert fake.calls == ["sid"]


def test_load_secret_returns_empty_on_client_error(monkeypatch: pytest.MonkeyPatch) -> None:
    error = ClientError({"Error": {"Code": "ResourceNotFoundException"}}, "GetSecretValue")
    _patch_client(monkeypatch, _FakeClient(error=error))
    assert config.load_secret("missing") == {}


@pytest.mark.parametrize(
    "payload",
    [{}, {"SecretString": ""}, {"SecretString": "not json"}, {"SecretString": "[1, 2]"}],
)
def test_load_secret_returns_empty_on_bad_payload(
    monkeypatch: pytest.MonkeyPatch, payload: dict[str, Any]
) -> None:
    _patch_client(monkeypatch, _FakeClient(payload))
    assert config.load_secret("sid") == {}


def test_get_settings_uses_defaults_when_secrets_disabled(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.delenv("APP_USE_SECRETS_MANAGER", raising=False)
    monkeypatch.setenv("APP_ENV", "unit")
    config.get_settings.cache_clear()
    settings = config.get_settings()
    assert settings.environment == "unit"
    assert settings.secrets_source == "defaults"
    assert settings.order_page_size == 50
    assert settings.feature_orders_v2 is False


def test_get_settings_reads_secret_values(monkeypatch: pytest.MonkeyPatch) -> None:
    secret = {"environment": "emulated", "order_page_size": "1", "feature_orders_v2": "true"}
    _patch_client(monkeypatch, _FakeClient({"SecretString": json.dumps(secret)}))
    monkeypatch.setenv("APP_USE_SECRETS_MANAGER", "true")
    config.get_settings.cache_clear()
    settings = config.get_settings()
    assert (settings.environment, settings.order_page_size, settings.feature_orders_v2) == (
        "emulated",
        1,
        True,
    )
    assert settings.secrets_source == "secretsmanager"


def test_get_settings_survives_a_non_numeric_page_size(monkeypatch: pytest.MonkeyPatch) -> None:
    _patch_client(monkeypatch, _FakeClient({"SecretString": '{"order_page_size": "many"}'}))
    monkeypatch.setenv("APP_USE_SECRETS_MANAGER", "true")
    config.get_settings.cache_clear()
    assert config.get_settings().order_page_size == 50


def test_secrets_client_honours_endpoint_override(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("AWS_ENDPOINT_URL", "http://localhost:4566")
    monkeypatch.setenv("AWS_DEFAULT_REGION", "us-east-1")
    monkeypatch.setenv("AWS_ACCESS_KEY_ID", "test")
    monkeypatch.setenv("AWS_SECRET_ACCESS_KEY", "test")  # noqa: S105
    client = config.secrets_client()
    assert client.meta.endpoint_url == "http://localhost:4566"
