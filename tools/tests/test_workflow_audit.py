"""Tests for the workflow auditor. Fixtures are written to tmp_path — no network."""

from __future__ import annotations

import json
import textwrap
from pathlib import Path

import pytest

from pipeline_tools import workflow_audit


def write(tmp_path: Path, name: str, body: str) -> Path:
    path = tmp_path / name
    path.write_text(textwrap.dedent(body).lstrip(), encoding="utf-8")
    return path


CLEAN = """
    name: clean
    on:
      pull_request:
    permissions:
      contents: read
    jobs:
      build:
        runs-on: ubuntu-latest
        permissions:
          contents: read
        steps:
          - run: echo hello
"""


def test_a_clean_workflow_has_no_findings(tmp_path: Path) -> None:
    assert workflow_audit.audit_file(write(tmp_path, "clean.yml", CLEAN)) == []


def test_a_job_without_permissions_is_flagged(tmp_path: Path) -> None:
    path = write(
        tmp_path,
        "no-perms.yml",
        """
        name: no-perms
        on: push
        jobs:
          build:
            runs-on: ubuntu-latest
            steps:
              - run: echo hello
        """,
    )
    findings = workflow_audit.audit_file(path)
    assert [f.rule for f in findings] == ["explicit-permissions"]
    assert findings[0].job == "build"


def test_a_top_level_permissions_block_covers_its_jobs(tmp_path: Path) -> None:
    path = write(
        tmp_path,
        "top-level.yml",
        """
        name: top-level
        on: push
        permissions:
          contents: read
        jobs:
          build:
            runs-on: ubuntu-latest
            steps:
              - run: echo hello
        """,
    )
    assert workflow_audit.audit_file(path) == []


def test_pull_request_target_checking_out_pr_code_is_flagged(tmp_path: Path) -> None:
    path = write(
        tmp_path,
        "prt.yml",
        """
        name: prt
        on: pull_request_target
        permissions:
          contents: read
        jobs:
          build:
            runs-on: ubuntu-latest
            permissions:
              contents: read
            steps:
              - uses: actions/checkout@v4
                with:
                  ref: ${{ github.event.pull_request.head.sha }}
        """,
    )
    assert [f.rule for f in workflow_audit.audit_file(path)] == ["pull-request-target-checkout"]


def test_pull_request_target_without_a_pr_checkout_is_allowed(tmp_path: Path) -> None:
    path = write(
        tmp_path,
        "prt-safe.yml",
        """
        name: prt-safe
        on: pull_request_target
        permissions:
          contents: read
        jobs:
          label:
            runs-on: ubuntu-latest
            permissions:
              pull-requests: write
            steps:
              - uses: actions/checkout@v4
        """,
    )
    assert workflow_audit.audit_file(path) == []


@pytest.mark.parametrize(
    "expression",
    [
        "${{ github.event.issue.body }}",
        "${{ github.event.pull_request.title }}",
        "${{ github.event.comment.body }}",
        "${{ github.head_ref }}",
        "${{ github.event.head_commit.message }}",
    ],
)
def test_untrusted_context_in_run_is_flagged(tmp_path: Path, expression: str) -> None:
    path = write(
        tmp_path,
        "inject.yml",
        f"""
        name: inject
        on: pull_request
        permissions:
          contents: read
        jobs:
          build:
            runs-on: ubuntu-latest
            permissions:
              contents: read
            steps:
              - run: echo "{expression}"
        """,
    )
    findings = workflow_audit.audit_file(path)
    assert [f.rule for f in findings] == ["untrusted-interpolation"]


def test_untrusted_context_passed_through_env_is_allowed(tmp_path: Path) -> None:
    path = write(
        tmp_path,
        "safe-env.yml",
        """
        name: safe-env
        on: pull_request
        permissions:
          contents: read
        jobs:
          build:
            runs-on: ubuntu-latest
            permissions:
              contents: read
            env:
              BODY: ${{ github.event.pull_request.body }}
            steps:
              - run: echo "$BODY"
        """,
    )
    assert workflow_audit.audit_file(path) == []


def test_unparseable_yaml_is_reported_not_raised(tmp_path: Path) -> None:
    path = write(tmp_path, "broken.yml", "name: [unclosed\n")
    findings = workflow_audit.audit_file(path)
    assert findings[0].rule == "unparseable"


def test_a_non_mapping_document_is_reported(tmp_path: Path) -> None:
    path = write(tmp_path, "list.yml", "- one\n- two\n")
    assert workflow_audit.audit_file(path)[0].rule == "unparseable"


def test_discover_expands_directories(tmp_path: Path) -> None:
    write(tmp_path, "a.yml", CLEAN)
    write(tmp_path, "b.yaml", CLEAN)
    (tmp_path / "notes.txt").write_text("ignored", encoding="utf-8")
    assert [p.name for p in workflow_audit.discover([str(tmp_path)])] == ["a.yml", "b.yaml"]


def test_main_returns_zero_and_writes_a_summary(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    write(tmp_path, "clean.yml", CLEAN)
    summary = tmp_path / "summary.md"
    monkeypatch.setenv("GITHUB_STEP_SUMMARY", str(summary))
    assert workflow_audit.main([str(tmp_path), "--json"]) == 0
    assert json.loads(capsys.readouterr().out)["ok"] is True
    assert "no findings" in summary.read_text(encoding="utf-8")


def test_main_returns_one_on_findings(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    write(tmp_path, "bad.yml", "name: bad\non: push\njobs:\n  b:\n    runs-on: ubuntu-latest\n")
    assert workflow_audit.main([str(tmp_path), "--json"]) == 1
    payload = json.loads(capsys.readouterr().out)
    assert payload["ok"] is False and payload["findings"][0]["rule"] == "explicit-permissions"


def test_main_returns_usage_error_when_nothing_matches(tmp_path: Path) -> None:
    assert workflow_audit.main([str(tmp_path / "missing")]) == 2


def test_render_markdown_lists_each_finding() -> None:
    findings = [workflow_audit.Finding("f.yml", "j", "rule-name", "why")]
    rendered = workflow_audit.render_markdown(findings, 1)
    assert "rule-name" in rendered and "| `f.yml` |" in rendered


def test_this_repository_passes_its_own_audit() -> None:
    """The repo must satisfy the rule it publishes. This is the real gate."""
    workflows = Path(__file__).resolve().parents[2] / ".github" / "workflows"
    assert workflows.is_dir()
    findings = [
        f
        for path in workflow_audit.discover([str(workflows)])
        for f in workflow_audit.audit_file(path)
    ]
    assert findings == [], findings
