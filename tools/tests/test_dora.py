"""Tests for the DORA calculator. Run payloads are fixtures — no GitHub API."""

from __future__ import annotations

import json
from typing import Any

import pytest

from pipeline_tools import dora


def run(
    conclusion: str,
    created: str,
    updated: str,
    authored: str | None = None,
) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "conclusion": conclusion,
        "created_at": created,
        "updated_at": updated,
    }
    if authored:
        payload["head_commit"] = {"timestamp": authored}
    return payload


def test_deployment_frequency_counts_successes_per_day() -> None:
    runs = [
        run("success", "2026-08-01T00:00:00Z", "2026-08-01T00:10:00Z"),
        run("success", "2026-08-02T00:00:00Z", "2026-08-02T00:10:00Z"),
        run("failure", "2026-08-03T00:00:00Z", "2026-08-03T00:10:00Z"),
    ]
    metrics = dora.compute(runs, window_days=10)
    assert metrics.deployment_frequency_per_day == 0.2
    assert metrics.successful_deployments == 2
    assert metrics.failed_deployments == 1


def test_lead_time_is_measured_from_the_commit_to_the_deploy() -> None:
    runs = [
        run("success", "2026-08-01T00:00:00Z", "2026-08-01T04:00:00Z", "2026-08-01T00:00:00Z"),
        run("success", "2026-08-02T00:00:00Z", "2026-08-02T02:00:00Z", "2026-08-02T00:00:00Z"),
    ]
    assert dora.compute(runs, window_days=7).lead_time_hours_median == 3.0


def test_lead_time_ignores_a_commit_timestamp_after_the_deploy() -> None:
    """A rebased or amended commit can be newer than the deploy that shipped it."""
    runs = [run("success", "2026-08-01T00:00:00Z", "2026-08-01T01:00:00Z", "2026-08-02T00:00:00Z")]
    assert dora.compute(runs, window_days=7).lead_time_hours_median is None


def test_change_failure_rate_is_failures_over_all_deployments() -> None:
    runs = [
        run("success", "2026-08-01T00:00:00Z", "2026-08-01T00:01:00Z"),
        run("failure", "2026-08-02T00:00:00Z", "2026-08-02T00:01:00Z"),
        run("failure", "2026-08-03T00:00:00Z", "2026-08-03T00:01:00Z"),
        run("success", "2026-08-04T00:00:00Z", "2026-08-04T00:01:00Z"),
    ]
    assert dora.compute(runs, window_days=30).change_failure_rate == 0.5


def test_time_to_restore_measures_first_failure_to_next_success() -> None:
    runs = [
        run("failure", "2026-08-01T00:00:00Z", "2026-08-01T00:00:00Z"),
        run("failure", "2026-08-01T01:00:00Z", "2026-08-01T01:00:00Z"),
        run("success", "2026-08-01T02:00:00Z", "2026-08-01T02:00:00Z"),
    ]
    # First failure at 00:00, restored at 02:00 — the second failure is the same
    # incident, not a new one.
    assert dora.compute(runs, window_days=30).mttr_hours_median == 2.0


def test_an_unresolved_failure_does_not_produce_a_restore_time() -> None:
    runs = [run("failure", "2026-08-01T00:00:00Z", "2026-08-01T00:00:00Z")]
    assert dora.compute(runs, window_days=30).mttr_hours_median is None


def test_cancelled_runs_are_not_deployments() -> None:
    runs = [
        run("cancelled", "2026-08-01T00:00:00Z", "2026-08-01T00:01:00Z"),
        run("skipped", "2026-08-01T00:00:00Z", "2026-08-01T00:01:00Z"),
    ]
    metrics = dora.compute(runs, window_days=30)
    assert metrics.deployments == 0
    assert metrics.change_failure_rate is None


def test_an_empty_window_reports_no_rates() -> None:
    metrics = dora.compute([], window_days=30)
    assert metrics.deployments == 0
    assert metrics.deployment_frequency_per_day == 0.0
    assert metrics.lead_time_hours_median is None


def test_render_markdown_states_each_definition() -> None:
    rendered = dora.render_markdown(dora.compute([], 30), "deploy.yml", "main")
    assert "Deployment frequency" in rendered
    assert "median commit-authored → deploy-finished" in rendered


def test_main_requires_a_token(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("GITHUB_TOKEN", raising=False)
    monkeypatch.delenv("GH_TOKEN", raising=False)
    assert dora.main(["--repo", "acme/app"]) == 2


def test_main_rejects_a_non_positive_window(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("GITHUB_TOKEN", "t")
    assert dora.main(["--repo", "acme/app", "--days", "0"]) == 2


def test_main_writes_a_summary_and_json(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Any, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.setenv("GITHUB_TOKEN", "t")
    summary = tmp_path / "summary.md"
    monkeypatch.setenv("GITHUB_STEP_SUMMARY", str(summary))
    monkeypatch.setattr(
        dora,
        "fetch_runs",
        lambda *a, **k: [run("success", "2026-08-01T00:00:00Z", "2026-08-01T00:05:00Z")],
    )
    assert dora.main(["--repo", "acme/app", "--json"]) == 0
    assert json.loads(capsys.readouterr().out)["successful_deployments"] == 1
    assert "DORA metrics" in summary.read_text(encoding="utf-8")
