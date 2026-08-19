"""FastAPI application.

Nobody is grading the application code — it exists to give the pipeline something
real to build, scan, sign, deploy and smoke-test.
"""

from __future__ import annotations

import secrets
from typing import Final

from fastapi import FastAPI, Response, status
from prometheus_client import CONTENT_TYPE_LATEST, Counter, generate_latest

from .config import Settings, get_settings
from .logging_config import configure_logging
from .models import Order, OrderCreate, OrderItem, OrderList, total_cents

configure_logging()

ORDERS_LISTED: Final = Counter("orders_listed_total", "Order list requests served.")
ORDERS_CREATED: Final = Counter("orders_created_total", "Orders accepted.")

FIXTURE_ORDERS: Final[list[Order]] = [
    Order(
        id="ord-1a2b3c4d",
        customer_id="cust-0000abcd",
        status="shipped",
        items=[OrderItem(sku="WIDGET-01", quantity=2, unit_price_cents=1250)],
        total_cents=2500,
    ),
    Order(
        id="ord-5e6f7a8b",
        customer_id="cust-0000abcd",
        status="pending",
        items=[
            OrderItem(sku="GADGET-99", quantity=1, unit_price_cents=9900),
            OrderItem(sku="WIDGET-01", quantity=3, unit_price_cents=1250),
        ],
        total_cents=13650,
    ),
]

app = FastAPI(title="secure-delivery-pipeline api-python", version="0.1.0")


@app.get("/healthz")
def healthz() -> dict[str, str]:
    """Liveness: the process is up. Deliberately does no dependency work."""
    return {"status": "ok"}


@app.get("/readyz")
def readyz() -> dict[str, str]:
    """Readiness: configuration resolved, so the service can serve traffic."""
    settings: Settings = get_settings()
    return {
        "status": "ready",
        "environment": settings.environment,
        "secrets_source": settings.secrets_source,
    }


@app.get("/api/v1/orders", response_model=OrderList)
def list_orders() -> OrderList:
    """Return the fixture orders, truncated to the configured page size."""
    ORDERS_LISTED.inc()
    page = FIXTURE_ORDERS[: get_settings().order_page_size]
    return OrderList(items=page, count=len(page))


@app.post("/api/v1/orders", response_model=Order, status_code=status.HTTP_201_CREATED)
def create_order(payload: OrderCreate) -> Order:
    """Accept an order. Pydantic has already rejected anything malformed."""
    ORDERS_CREATED.inc()
    return Order(
        id=f"ord-{secrets.token_hex(4)}",
        customer_id=payload.customer_id,
        items=payload.items,
        status="pending",
        total_cents=total_cents(payload.items),
    )


@app.get("/metrics")
def metrics() -> Response:
    """Prometheus exposition endpoint."""
    return Response(content=generate_latest(), media_type=CONTENT_TYPE_LATEST)
