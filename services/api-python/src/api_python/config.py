"""Application settings, optionally sourced from AWS Secrets Manager.

This is the module that gives the pipeline a genuine AWS-SDK code path. The client
honours ``AWS_ENDPOINT_URL``, so the same code talks to the in-runner emulator
during integration tests and to the real service in production.
"""

from __future__ import annotations

import json
import logging
import os
from dataclasses import dataclass
from functools import lru_cache
from typing import TYPE_CHECKING

import boto3
from botocore.exceptions import BotoCoreError, ClientError

if TYPE_CHECKING:  # stubs are a dev-only dependency, never installed in the image
    from mypy_boto3_secretsmanager.client import SecretsManagerClient

LOGGER = logging.getLogger(__name__)

DEFAULT_SECRET_ID = "secure-delivery-pipeline/api-python"  # noqa: S105 — a secret name, not a value


@dataclass(frozen=True)
class Settings:
    """Effective runtime configuration."""

    environment: str
    order_page_size: int
    feature_orders_v2: bool
    secrets_source: str


def secrets_client() -> SecretsManagerClient:
    """Build a Secrets Manager client honouring ``AWS_ENDPOINT_URL``."""
    return boto3.client(
        "secretsmanager",
        endpoint_url=os.getenv("AWS_ENDPOINT_URL"),
        region_name=os.getenv("AWS_DEFAULT_REGION", "us-east-1"),
    )


def load_secret(secret_id: str) -> dict[str, str]:
    """Fetch and decode a JSON secret.

    Returns an empty mapping when the secret is absent or unreachable — the service
    must start with defaults rather than crash-loop on a configuration lookup.
    """
    try:
        response = secrets_client().get_secret_value(SecretId=secret_id)
    except (BotoCoreError, ClientError) as exc:
        LOGGER.warning("secret unavailable, falling back to defaults", extra={"error": str(exc)})
        return {}

    raw = response.get("SecretString")
    if not raw:
        LOGGER.warning("secret has no SecretString, falling back to defaults")
        return {}

    try:
        decoded = json.loads(raw)
    except json.JSONDecodeError:
        LOGGER.warning("secret is not valid JSON, falling back to defaults")
        return {}

    if not isinstance(decoded, dict):
        LOGGER.warning("secret is not a JSON object, falling back to defaults")
        return {}

    return {str(key): str(value) for key, value in decoded.items()}


def _as_bool(value: str) -> bool:
    return value.strip().lower() in {"1", "true", "yes", "on"}


def _as_int(value: str, fallback: int) -> int:
    try:
        return int(value)
    except ValueError:
        return fallback


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    """Resolve settings once per process: Secrets Manager first, then defaults."""
    secret_id = os.getenv("APP_SECRET_ID", DEFAULT_SECRET_ID)
    secret = load_secret(secret_id) if os.getenv("APP_REMOTE_CONFIG") == "true" else {}
    return Settings(
        environment=secret.get("environment", os.getenv("APP_ENV", "local")),
        order_page_size=_as_int(secret.get("order_page_size", "50"), 50),
        feature_orders_v2=_as_bool(secret.get("feature_orders_v2", "false")),
        secrets_source="secretsmanager" if secret else "defaults",
    )
