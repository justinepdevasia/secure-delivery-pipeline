"""Tests for the sticky PR comment helper. The GitHub API is stubbed."""

from __future__ import annotations

import json
from typing import Any

import pytest

from pipeline_tools import pr_comment
from pipeline_tools.httpc import HttpError, Response


def test_marker_is_an_html_comment() -> None:
    assert pr_comment.marker("sbom-diff") == "<!-- pipeline-tools:sbom-diff -->"


def test_find_existing_matches_only_its_own_marker(monkeypatch: pytest.MonkeyPatch) -> None:
    comments = [
        {"id": 1, "body": "a human said something"},
        {"id": 2, "body": f"{pr_comment.marker('dora')}\nother bot"},
        {"id": 3, "body": f"{pr_comment.marker('sbom-diff')}\nours"},
    ]
    monkeypatch.setattr(pr_comment, "get_json", lambda *a, **k: comments)
    assert pr_comment.find_existing("acme/app", 7, "sbom-diff", "t") == 3


def test_find_existing_returns_none_when_absent(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(pr_comment, "get_json", lambda *a, **k: [{"id": 1, "body": "hello"}])
    assert pr_comment.find_existing("acme/app", 7, "sbom-diff", "t") is None


def test_find_existing_handles_an_empty_thread(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(pr_comment, "get_json", lambda *a, **k: [])
    assert pr_comment.find_existing("acme/app", 7, "sbom-diff", "t") is None


def test_find_existing_paginates(monkeypatch: pytest.MonkeyPatch) -> None:
    pages = {
        1: [{"id": i, "body": "filler"} for i in range(100)],
        2: [{"id": 999, "body": f"{pr_comment.marker('x')}\nfound"}],
    }
    calls: list[str] = []

    def fake(url: str, **kwargs: Any) -> Any:
        calls.append(url)
        return pages[2] if "page=2" in url else pages[1]

    monkeypatch.setattr(pr_comment, "get_json", fake)
    assert pr_comment.find_existing("acme/app", 7, "x", "t") == 999
    assert len(calls) == 2


def test_post_creates_when_no_comment_exists(monkeypatch: pytest.MonkeyPatch) -> None:
    captured: dict[str, Any] = {}
    monkeypatch.setattr(pr_comment, "find_existing", lambda *a, **k: None)

    def fake_request(url: str, **kwargs: Any) -> Response:
        captured.update({"url": url, **kwargs})
        return Response(status=201, body=b'{"id": 5, "html_url": "u"}')

    monkeypatch.setattr(pr_comment, "request", fake_request)
    result = pr_comment.post("acme/app", 7, "sbom-diff", "body text", "t")

    assert result["id"] == 5
    assert captured["method"] == "POST"
    assert captured["url"].endswith("/repos/acme/app/issues/7/comments")
    assert pr_comment.marker("sbom-diff") in json.loads(captured["body"])["body"]


def test_post_updates_the_existing_comment_instead_of_adding_one(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    captured: dict[str, Any] = {}
    monkeypatch.setattr(pr_comment, "find_existing", lambda *a, **k: 42)

    def fake_request(url: str, **kwargs: Any) -> Response:
        captured.update({"url": url, **kwargs})
        return Response(status=200, body=b'{"id": 42}')

    monkeypatch.setattr(pr_comment, "request", fake_request)
    pr_comment.post("acme/app", 7, "sbom-diff", "updated", "t")

    assert captured["method"] == "PATCH"
    assert captured["url"].endswith("/repos/acme/app/issues/comments/42")


def test_main_requires_a_pull_request_number(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("GITHUB_TOKEN", "t")
    assert pr_comment.main(["--repo", "acme/app", "--name", "x", "--body", "b"]) == 2


def test_main_requires_a_token(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("GITHUB_TOKEN", raising=False)
    monkeypatch.delenv("GH_TOKEN", raising=False)
    assert pr_comment.main(["--repo", "acme/app", "--pr", "1", "--name", "x", "--body", "b"]) == 2


def test_main_requires_a_body(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("GITHUB_TOKEN", "t")
    assert pr_comment.main(["--repo", "acme/app", "--pr", "1", "--name", "x"]) == 2


def test_main_reads_the_body_from_a_file(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Any, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.setenv("GITHUB_TOKEN", "t")
    body = tmp_path / "body.md"
    body.write_text("### from a file", encoding="utf-8")
    captured: dict[str, Any] = {}

    def fake_post(repo: str, pr: int, name: str, text: str, token: str, **kwargs: Any) -> Any:
        captured["text"] = text
        return {"id": 1, "html_url": "u"}

    monkeypatch.setattr(pr_comment, "post", fake_post)
    assert (
        pr_comment.main(
            ["--repo", "acme/app", "--pr", "3", "--name", "x", "--body-file", str(body), "--json"]
        )
        == 0
    )
    assert captured["text"] == "### from a file"
    assert json.loads(capsys.readouterr().out)["ok"] is True


def test_main_reports_an_api_failure(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("GITHUB_TOKEN", "t")

    def raise_http(*args: Any, **kwargs: Any) -> Any:
        raise HttpError(404, "u", "not found")

    monkeypatch.setattr(pr_comment, "post", raise_http)
    assert pr_comment.main(["--repo", "acme/app", "--pr", "1", "--name", "x", "--body", "b"]) == 1
