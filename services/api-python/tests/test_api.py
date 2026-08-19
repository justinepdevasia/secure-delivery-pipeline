"""API surface tests. No network, no AWS."""

from __future__ import annotations

from collections.abc import Iterator

import pytest
from fastapi.testclient import TestClient

from api_python.config import get_settings
from api_python.main import app


@pytest.fixture
def client() -> Iterator[TestClient]:
    get_settings.cache_clear()
    with TestClient(app) as test_client:
        yield test_client


def test_healthz(client: TestClient) -> None:
    response = client.get("/healthz")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_readyz_reports_configuration_source(client: TestClient) -> None:
    response = client.get("/readyz")
    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "ready"
    assert body["secrets_source"] == "defaults"


def test_list_orders_shape(client: TestClient) -> None:
    response = client.get("/api/v1/orders")
    assert response.status_code == 200
    body = response.json()
    assert body["count"] == len(body["items"]) == 2
    assert body["items"][0]["id"] == "ord-1a2b3c4d"


def test_list_orders_respects_page_size(
    client: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr("api_python.main.FIXTURE_ORDERS", [])
    assert client.get("/api/v1/orders").json() == {"items": [], "count": 0}


def test_create_order_computes_total(client: TestClient) -> None:
    payload = {
        "customer_id": "cust-0000abcd",
        "items": [
            {"sku": "WIDGET-01", "quantity": 2, "unit_price_cents": 500},
            {"sku": "GADGET-99", "quantity": 1, "unit_price_cents": 250},
        ],
    }
    response = client.post("/api/v1/orders", json=payload)
    assert response.status_code == 201
    body = response.json()
    assert body["total_cents"] == 1250
    assert body["status"] == "pending"
    assert body["id"].startswith("ord-")


@pytest.mark.parametrize(
    "payload",
    [
        {"customer_id": "nope", "items": [{"sku": "A-1", "quantity": 1, "unit_price_cents": 1}]},
        {"customer_id": "cust-0000abcd", "items": []},
        {
            "customer_id": "cust-0000abcd",
            "items": [{"sku": "lower-case", "quantity": 1, "unit_price_cents": 1}],
        },
        {
            "customer_id": "cust-0000abcd",
            "items": [{"sku": "WIDGET-01", "quantity": 0, "unit_price_cents": 1}],
        },
    ],
)
def test_create_order_rejects_invalid_payloads(client: TestClient, payload: dict) -> None:
    assert client.post("/api/v1/orders", json=payload).status_code == 422


def test_metrics_exposes_counters(client: TestClient) -> None:
    client.get("/api/v1/orders")
    response = client.get("/metrics")
    assert response.status_code == 200
    assert "orders_listed_total" in response.text
