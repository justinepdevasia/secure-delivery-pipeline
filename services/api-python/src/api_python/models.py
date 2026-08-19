"""Request and response models. Validation lives here, not in the handlers."""

from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, Field

OrderStatus = Literal["pending", "shipped", "cancelled"]


class OrderItem(BaseModel):
    """A single line on an order."""

    sku: str = Field(min_length=3, max_length=32, pattern=r"^[A-Z0-9-]+$")
    quantity: int = Field(ge=1, le=100)
    unit_price_cents: int = Field(ge=0, le=10_000_000)


class OrderCreate(BaseModel):
    """Inbound payload for ``POST /api/v1/orders``."""

    customer_id: str = Field(pattern=r"^cust-[0-9a-f]{8}$")
    items: list[OrderItem] = Field(min_length=1, max_length=20)


class Order(OrderCreate):
    """A persisted order."""

    id: str = Field(pattern=r"^ord-[0-9a-f]{8}$")
    status: OrderStatus
    total_cents: int


class OrderList(BaseModel):
    """Envelope for ``GET /api/v1/orders``."""

    items: list[Order]
    count: int


def total_cents(items: list[OrderItem]) -> int:
    """Order total in cents. Kept out of the model so ``Order`` can store it."""
    return sum(item.quantity * item.unit_price_cents for item in items)
