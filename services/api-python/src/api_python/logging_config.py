"""Structured JSON logging.

Logs go to stderr so stdout stays free for machine-readable output, matching the
convention the Bash tooling in ``scripts/`` follows.
"""

from __future__ import annotations

import logging
import sys

from pythonjsonlogger.json import JsonFormatter

_FORMAT = "%(asctime)s %(levelname)s %(name)s %(message)s"


def configure_logging(level: int = logging.INFO) -> None:
    """Install a JSON formatter on the root logger. Idempotent."""
    root = logging.getLogger()
    root.setLevel(level)
    for existing in list(root.handlers):
        root.removeHandler(existing)
    handler = logging.StreamHandler(sys.stderr)
    handler.setFormatter(JsonFormatter(_FORMAT, rename_fields={"asctime": "timestamp"}))
    root.addHandler(handler)
