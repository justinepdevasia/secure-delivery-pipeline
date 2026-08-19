"""DORA metrics computed from the GitHub API.

Deployment frequency, lead time for changes, change failure rate and time to
restore, derived from workflow runs and the commits behind them. Reported so a
deploy summary carries trend information rather than a bare "success".

The definitions are stated explicitly in the output, because DORA metrics are
easy to quote and easy to compute four different ways.

Exit codes: 0 computed | 1 the API call failed | 2 usage error
"""

from __future__ import annotations

import argparse
import logging
import os
import sys
from dataclasses import asdict, dataclass
from datetime import UTC, datetime, timedelta
from typing import Any

from .cli import EX_FAIL, EX_OK, EX_USAGE, configure_logging, emit_json, write_step_summary
from .httpc import HttpError, get_json

LOGGER = logging.getLogger("dora")

API = "https://api.github.com"


@dataclass(frozen=True)
class Metrics:
    """The four keys, plus the inputs they were derived from."""

    window_days: int
    deployments: int
    deployment_frequency_per_day: float
    lead_time_hours_median: float | None
    change_failure_rate: float | None
    mttr_hours_median: float | None
    successful_deployments: int
    failed_deployments: int


def _parse(timestamp: str) -> datetime:
    return datetime.fromisoformat(timestamp.replace("Z", "+00:00"))


def _median(values: list[float]) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    middle = len(ordered) // 2
    if len(ordered) % 2:
        return ordered[middle]
    return (ordered[middle - 1] + ordered[middle]) / 2


def fetch_runs(
    repo: str, workflow: str, branch: str, since: datetime, token: str, *, api: str = API
) -> list[dict[str, Any]]:
    """Completed runs of one workflow on one branch, newest first."""
    runs: list[dict[str, Any]] = []
    page = 1
    while page <= 10:  # 1000 runs is far past any useful window
        payload = get_json(
            f"{api}/repos/{repo}/actions/workflows/{workflow}/runs"
            f"?branch={branch}&status=completed&per_page=100&page={page}",
            token=token,
        )
        batch = payload.get("workflow_runs") or []
        if not batch:
            break
        runs.extend(batch)
        if _parse(batch[-1]["created_at"]) < since or len(batch) < 100:
            break
        page += 1
    return [run for run in runs if _parse(run["created_at"]) >= since]


def compute(runs: list[dict[str, Any]], window_days: int) -> Metrics:
    """Derive the four metrics from a list of completed deploy runs."""
    deployments = [r for r in runs if r.get("conclusion") in {"success", "failure"}]
    successes = [r for r in deployments if r.get("conclusion") == "success"]
    failures = [r for r in deployments if r.get("conclusion") == "failure"]

    # Lead time: commit authored -> the deploy that carried it finished.
    lead_times: list[float] = []
    for run in successes:
        head_commit = run.get("head_commit") or {}
        authored = head_commit.get("timestamp")
        finished = run.get("updated_at")
        if authored and finished:
            delta = _parse(finished) - _parse(authored)
            if delta >= timedelta(0):
                lead_times.append(delta.total_seconds() / 3600)

    # Time to restore: a failed deploy until the next successful one on the branch.
    ordered = sorted(deployments, key=lambda r: _parse(r["created_at"]))
    restores: list[float] = []
    broken_since: datetime | None = None
    for run in ordered:
        if run.get("conclusion") == "failure" and broken_since is None:
            broken_since = _parse(run["updated_at"])
        elif run.get("conclusion") == "success" and broken_since is not None:
            restores.append((_parse(run["updated_at"]) - broken_since).total_seconds() / 3600)
            broken_since = None

    total = len(deployments)
    return Metrics(
        window_days=window_days,
        deployments=total,
        deployment_frequency_per_day=round(len(successes) / window_days, 3),
        lead_time_hours_median=(
            round(value, 2) if (value := _median(lead_times)) is not None else None
        ),
        change_failure_rate=(round(len(failures) / total, 3) if total else None),
        mttr_hours_median=(round(value, 2) if (value := _median(restores)) is not None else None),
        successful_deployments=len(successes),
        failed_deployments=len(failures),
    )


def render_markdown(metrics: Metrics, workflow: str, branch: str) -> str:
    def show(value: float | None, suffix: str = "") -> str:
        return "—" if value is None else f"{value}{suffix}"

    return (
        "### DORA metrics\n\n"
        f"`{workflow}` on `{branch}`, last {metrics.window_days} days "
        f"({metrics.deployments} deployment(s)).\n\n"
        "| metric | value | definition |\n| --- | --- | --- |\n"
        f"| Deployment frequency | {show(metrics.deployment_frequency_per_day, '/day')} "
        "| successful deploy runs ÷ window |\n"
        f"| Lead time for changes | {show(metrics.lead_time_hours_median, 'h')} "
        "| median commit-authored → deploy-finished |\n"
        f"| Change failure rate | {show(metrics.change_failure_rate)} "
        "| failed ÷ all deploy runs |\n"
        f"| Time to restore | {show(metrics.mttr_hours_median, 'h')} "
        "| median first failure → next success |\n"
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="dora-metrics",
        description="Compute DORA metrics from GitHub Actions deploy runs.",
        epilog="Exit codes: 0 computed, 1 API failure, 2 usage error.",
    )
    parser.add_argument("--repo", default=os.getenv("GITHUB_REPOSITORY"), help="owner/name")
    parser.add_argument("--workflow", default="deploy-eks-emulated.yml")
    parser.add_argument("--branch", default="main")
    parser.add_argument("--days", type=int, default=30, help="Window in days. Default 30")
    parser.add_argument("--json", action="store_true", help="Emit metrics as JSON on stdout")
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args(argv)

    configure_logging(args.verbose)

    token = os.getenv("GITHUB_TOKEN") or os.getenv("GH_TOKEN") or ""
    if not args.repo or not token:
        LOGGER.error("--repo and a GITHUB_TOKEN are both required")
        return EX_USAGE
    if args.days <= 0:
        LOGGER.error("--days must be positive")
        return EX_USAGE

    since = datetime.now(UTC) - timedelta(days=args.days)
    try:
        runs = fetch_runs(args.repo, args.workflow, args.branch, since, token)
    except HttpError as exc:
        LOGGER.error("could not read workflow runs: %s", exc)
        return EX_FAIL

    metrics = compute(runs, args.days)
    LOGGER.info(
        "%d deployment(s), %d successful, %d failed",
        metrics.deployments,
        metrics.successful_deployments,
        metrics.failed_deployments,
    )

    write_step_summary(
        render_markdown(metrics, args.workflow, args.branch), os.getenv("GITHUB_STEP_SUMMARY")
    )
    if args.json:
        emit_json({"ok": True, **asdict(metrics)})
    return EX_OK


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
