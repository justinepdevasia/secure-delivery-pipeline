"""Shared CLI plumbing: logging to stderr, JSON to stdout, explicit exit codes."""

from __future__ import annotations

import json
import logging
import sys
from typing import Any, Final

# Mirrors the exit codes used by scripts/lib/common.sh, so a workflow reads the
# same number the same way whether the step was Bash or Python.
EX_OK: Final = 0
EX_FAIL: Final = 1
EX_USAGE: Final = 2
EX_TIMEOUT: Final = 3
EX_VERIFY: Final = 4


def configure_logging(verbose: bool = False) -> None:
    """Log to stderr so stdout carries only machine-readable output."""
    logging.basicConfig(
        stream=sys.stderr,
        level=logging.DEBUG if verbose else logging.INFO,
        format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
        datefmt="%Y-%m-%dT%H:%M:%SZ",
    )


def emit_json(payload: Any) -> None:
    """Write a JSON document to stdout."""
    json.dump(payload, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")


def write_step_summary(markdown: str, path: str | None) -> None:
    """Append Markdown to $GITHUB_STEP_SUMMARY when running under Actions."""
    if not path:
        return
    with open(path, "a", encoding="utf-8") as handle:
        handle.write(markdown.rstrip() + "\n")
