"""Tests for the Datadog deploy gate. The API is stubbed — no network, no keys."""

from __future__ import annotations

import json
from typing import Any

import pytest

from pipeline_tools import datadog_gate
from pipeline_tools.httpc import HttpError


def monitor(id_: int, name: str, state: str) -> dict[str, Any]:
    return {"id": id_, "name": name, "overall_state": state}


def test_build_url_encodes_the_tag_filter() -> None:
    url = datadog_gate.build_url("datadoghq.eu", ["service:api", "env:prod"])
    assert url.startswith("https://api.datadoghq.eu/api/v1/monitor?")
    assert "service%3Aapi%2Cenv%3Aprod" in url


def test_build_url_without_tags_has_no_query() -> None:
    assert datadog_gate.build_url("datadoghq.com", []) == "https://api.datadoghq.com/api/v1/monitor"


def test_parse_monitors_ignores_junk_entries() -> None:
    parsed = datadog_gate.parse_monitors([monitor(1, "a", "OK"), "nonsense", None])
    assert [m.id for m in parsed] == [1]


def test_dry_run_is_the_default_and_sends_nothing(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.delenv("DD_DRY_RUN", raising=False)

    def explode(*args: Any, **kwargs: Any) -> Any:
        raise AssertionError("the gate must not call Datadog in dry-run mode")

    monkeypatch.setattr(datadog_gate, "get_json", explode)
    assert datadog_gate.main(["--service", "api-python", "--env", "production", "--json"]) == 0
    assert json.loads(capsys.readouterr().out)["dry_run"] is True


def test_dry_run_logs_the_exact_request(
    monkeypatch: pytest.MonkeyPatch, caplog: pytest.LogCaptureFixture
) -> None:
    monkeypatch.setenv("DD_DRY_RUN", "true")
    with caplog.at_level("INFO"):
        assert datadog_gate.main(["--service", "api-python", "--env", "prod"]) == 0
    assert any("api/v1/monitor" in record.getMessage() for record in caplog.records)


def test_missing_keys_outside_dry_run_is_a_usage_error(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("DD_DRY_RUN", "false")
    monkeypatch.delenv("DD_API_KEY", raising=False)
    monkeypatch.delenv("DD_APP_KEY", raising=False)
    assert datadog_gate.main(["--service", "api", "--env", "prod"]) == 2


def _live(monkeypatch: pytest.MonkeyPatch, payload: Any) -> None:
    monkeypatch.setenv("DD_DRY_RUN", "false")
    monkeypatch.setenv("DD_API_KEY", "k")
    monkeypatch.setenv("DD_APP_KEY", "a")
    monkeypatch.setattr(datadog_gate, "get_json", lambda *a, **k: payload)


def test_an_alerting_monitor_blocks_the_deploy(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    _live(monkeypatch, [monitor(1, "p99 latency", "Alert"), monitor(2, "errors", "OK")])
    assert datadog_gate.main(["--service", "api", "--env", "prod", "--json"]) == 4
    payload = json.loads(capsys.readouterr().out)
    assert payload["ok"] is False and payload["alerting"][0]["id"] == 1


def test_a_warning_monitor_does_not_block(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    _live(monkeypatch, [monitor(1, "p99 latency", "Warn")])
    assert datadog_gate.main(["--service", "api", "--env", "prod", "--json"]) == 0
    assert json.loads(capsys.readouterr().out)["ok"] is True


def test_no_data_does_not_block(monkeypatch: pytest.MonkeyPatch) -> None:
    """A monitor created five minutes ago must not block every deploy."""
    _live(monkeypatch, [monitor(1, "brand new", "No Data")])
    assert datadog_gate.main(["--service", "api", "--env", "prod"]) == 0


def test_all_clear_passes(monkeypatch: pytest.MonkeyPatch) -> None:
    _live(monkeypatch, [monitor(1, "a", "OK"), monitor(2, "b", "OK")])
    assert datadog_gate.main(["--service", "api", "--env", "prod"]) == 0


def test_an_api_failure_is_reported_not_swallowed(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("DD_DRY_RUN", "false")
    monkeypatch.setenv("DD_API_KEY", "k")
    monkeypatch.setenv("DD_APP_KEY", "a")

    def raise_http(*args: Any, **kwargs: Any) -> Any:
        raise HttpError(403, "https://api.datadoghq.com", "forbidden")

    monkeypatch.setattr(datadog_gate, "get_json", raise_http)
    assert datadog_gate.main(["--service", "api", "--env", "prod"]) == 1


def test_extra_tags_are_included_in_the_query(monkeypatch: pytest.MonkeyPatch) -> None:
    captured: dict[str, str] = {}
    monkeypatch.setenv("DD_DRY_RUN", "false")
    monkeypatch.setenv("DD_API_KEY", "k")
    monkeypatch.setenv("DD_APP_KEY", "a")

    def capture(url: str, **kwargs: Any) -> Any:
        captured["url"] = url
        return []

    monkeypatch.setattr(datadog_gate, "get_json", capture)
    assert datadog_gate.main(["--service", "api", "--env", "prod", "--extra-tag", "team:sre"]) == 0
    assert "team%3Asre" in captured["url"]


def test_render_markdown_reports_the_verdict() -> None:
    monitors = datadog_gate.parse_monitors([monitor(1, "a", "Alert")])
    rendered = datadog_gate.render_markdown(monitors, monitors, dry=False)
    assert "**Blocked**" in rendered
