"""Refuse to deploy on top of an already-broken service.

Queries Datadog monitor state for a service and environment and fails the deploy
if any monitor is alerting. Deploying into an active incident turns one problem
into two and destroys the signal that would have told you which change caused it.

DD_DRY_RUN=true (the default here) logs the exact request instead of sending it,
so the gate is demonstrable in a repository with no Datadog account.

Exit codes: 0 clear | 1 the API call failed | 2 usage error | 4 a monitor is alerting
"""

from __future__ import annotations

import argparse
import logging
import os
import sys
import urllib.parse
from dataclasses import dataclass
from typing import Any

from .cli import (
    EX_FAIL,
    EX_OK,
    EX_USAGE,
    EX_VERIFY,
    configure_logging,
    emit_json,
    write_step_summary,
)
from .httpc import HttpError, get_json

LOGGER = logging.getLogger("datadog_gate")

DEFAULT_SITE = "datadoghq.com"

# Datadog's overall_state values. "Alert" is the only one that stops a deploy;
# "Warn" and "No Data" are reported and allowed through, because blocking on
# No Data means a newly created monitor blocks every deploy.
BLOCKING_STATES = frozenset({"Alert"})
REPORTED_STATES = frozenset({"Alert", "Warn", "No Data"})


@dataclass(frozen=True)
class MonitorState:
    id: int
    name: str
    state: str


def build_url(site: str, tags: list[str]) -> str:
    """Monitor search URL for the given tags."""
    query = urllib.parse.urlencode({"monitor_tags": ",".join(tags)}) if tags else ""
    return f"https://api.{site}/api/v1/monitor" + (f"?{query}" if query else "")


def parse_monitors(payload: Any) -> list[MonitorState]:
    """Turn Datadog's monitor list into something worth printing."""
    monitors: list[MonitorState] = []
    for entry in payload if isinstance(payload, list) else []:
        if not isinstance(entry, dict):
            continue
        monitors.append(
            MonitorState(
                id=int(entry.get("id", 0)),
                name=str(entry.get("name", "<unnamed>")),
                state=str(entry.get("overall_state", "Unknown")),
            )
        )
    return monitors


def render_markdown(monitors: list[MonitorState], blocking: list[MonitorState], dry: bool) -> str:
    header = "### Datadog deploy gate\n\n"
    if dry:
        header += "_DD_DRY_RUN is set — the request was logged, not sent._\n\n"
    if not monitors:
        return header + "No monitors matched the query.\n"

    interesting = [m for m in monitors if m.state in REPORTED_STATES] or monitors[:5]
    rows = "\n".join(f"| {m.id} | {m.name} | {m.state} |" for m in interesting)
    verdict = (
        f"**Blocked** — {len(blocking)} monitor(s) alerting."
        if blocking
        else f"**Clear** — {len(monitors)} monitor(s) checked, none alerting."
    )
    return header + f"{verdict}\n\n| id | monitor | state |\n| --- | --- | --- |\n{rows}\n"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="datadog-gate",
        description="Fail a deploy when a Datadog monitor for the service is alerting.",
        epilog="Exit codes: 0 clear, 1 API failure, 2 usage error, 4 a monitor is alerting.",
    )
    parser.add_argument("--service", required=True, help="service tag value")
    parser.add_argument("--env", required=True, help="env tag value")
    parser.add_argument("--site", default=os.getenv("DD_SITE", DEFAULT_SITE))
    parser.add_argument(
        "--extra-tag",
        action="append",
        default=[],
        help="Additional monitor tag to filter on. Repeatable.",
    )
    parser.add_argument("--json", action="store_true", help="Emit the verdict as JSON")
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args(argv)

    configure_logging(args.verbose)

    tags = [f"service:{args.service}", f"env:{args.env}", *args.extra_tag]
    url = build_url(args.site, tags)

    # Default true: this repository has no Datadog account, and a gate that
    # silently passes because a key is missing would be worse than no gate.
    dry_run = os.getenv("DD_DRY_RUN", "true").strip().lower() not in {"0", "false", "no"}
    api_key = os.getenv("DD_API_KEY", "")
    app_key = os.getenv("DD_APP_KEY", "")

    if dry_run:
        LOGGER.info("DD_DRY_RUN: GET %s", url)
        LOGGER.info("DD_DRY_RUN: headers DD-API-KEY=<redacted> DD-APPLICATION-KEY=<redacted>")
        write_step_summary(render_markdown([], [], dry=True), os.getenv("GITHUB_STEP_SUMMARY"))
        if args.json:
            emit_json({"ok": True, "dry_run": True, "url": url, "tags": tags})
        return EX_OK

    if not api_key or not app_key:
        LOGGER.error("DD_API_KEY and DD_APP_KEY are required unless DD_DRY_RUN is set")
        return EX_USAGE

    try:
        payload = get_json(
            url,
            headers={"DD-API-KEY": api_key, "DD-APPLICATION-KEY": app_key},
        )
    except HttpError as exc:
        LOGGER.error("could not query Datadog: %s", exc)
        return EX_FAIL

    monitors = parse_monitors(payload)
    blocking = [m for m in monitors if m.state in BLOCKING_STATES]

    for monitor in monitors:
        if monitor.state in REPORTED_STATES:
            LOGGER.warning("monitor %d %r is %s", monitor.id, monitor.name, monitor.state)

    write_step_summary(
        render_markdown(monitors, blocking, dry=False), os.getenv("GITHUB_STEP_SUMMARY")
    )
    if args.json:
        emit_json(
            {
                "ok": not blocking,
                "dry_run": False,
                "checked": len(monitors),
                "alerting": [{"id": m.id, "name": m.name} for m in blocking],
            }
        )

    if blocking:
        LOGGER.error("%d monitor(s) alerting — refusing to deploy", len(blocking))
        return EX_VERIFY
    LOGGER.info("%d monitor(s) checked, none alerting", len(monitors))
    return EX_OK


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
