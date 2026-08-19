"""Emulator-backed test of the real boto3 code path.

Skipped unless ``AWS_ENDPOINT_URL`` points at a running AWS emulator, so the unit
test job stays offline. ``ci-python.yml`` runs this in its own job with the
emulator up: ``pytest -m integration``.
"""

from __future__ import annotations

import json
import os

import pytest

from api_python import config

pytestmark = [
    pytest.mark.integration,
    pytest.mark.skipif(
        not os.getenv("AWS_ENDPOINT_URL"),
        reason="requires an AWS emulator at AWS_ENDPOINT_URL",
    ),
]

SECRET_ID = "secure-delivery-pipeline/api-python"
SECRET_VALUE = {"environment": "emulated", "order_page_size": "1", "feature_orders_v2": "true"}


@pytest.fixture(scope="module")
def seeded_secret() -> str:
    client = config.secrets_client()
    try:
        client.create_secret(Name=SECRET_ID, SecretString=json.dumps(SECRET_VALUE))
    except client.exceptions.ResourceExistsException:
        client.put_secret_value(SecretId=SECRET_ID, SecretString=json.dumps(SECRET_VALUE))
    return SECRET_ID


def test_load_secret_round_trips_through_the_emulator(seeded_secret: str) -> None:
    assert config.load_secret(seeded_secret) == SECRET_VALUE


def test_settings_are_sourced_from_secrets_manager(
    seeded_secret: str, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("APP_USE_SECRETS_MANAGER", "true")
    monkeypatch.setenv("APP_SECRET_ID", seeded_secret)
    config.get_settings.cache_clear()
    settings = config.get_settings()
    assert settings.secrets_source == "secretsmanager"
    assert settings.environment == "emulated"
    assert settings.order_page_size == 1
    assert settings.feature_orders_v2 is True


def test_missing_secret_falls_back_to_defaults(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("APP_USE_SECRETS_MANAGER", "true")
    monkeypatch.setenv("APP_SECRET_ID", "secure-delivery-pipeline/does-not-exist")
    config.get_settings.cache_clear()
    assert config.get_settings().secrets_source == "defaults"
