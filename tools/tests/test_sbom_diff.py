"""Tests for the SBOM differ. Pure functions plus tmp_path files — no network."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from pipeline_tools import sbom_diff


def write_sbom(path: Path, components: list[dict[str, str]]) -> Path:
    path.write_text(
        json.dumps({"bomFormat": "CycloneDX", "specVersion": "1.5", "components": components}),
        encoding="utf-8",
    )
    return path


def test_load_components_keys_by_group_and_name(tmp_path: Path) -> None:
    path = write_sbom(
        tmp_path / "a.json",
        [
            {"name": "requests", "version": "2.0.0"},
            {"group": "org.acme", "name": "requests", "version": "3.0.0"},
        ],
    )
    assert sbom_diff.load_components(path) == {
        "requests": "2.0.0",
        "org.acme/requests": "3.0.0",
    }


def test_load_components_skips_unnamed_entries(tmp_path: Path) -> None:
    path = write_sbom(tmp_path / "a.json", [{"version": "1.0.0"}, {"name": "ok", "version": "1"}])
    assert sbom_diff.load_components(path) == {"ok": "1"}


def test_load_components_rejects_a_non_document(tmp_path: Path) -> None:
    path = tmp_path / "list.json"
    path.write_text("[1, 2]", encoding="utf-8")
    with pytest.raises(ValueError, match="not a CycloneDX document"):
        sbom_diff.load_components(path)


def test_diff_detects_additions_and_removals() -> None:
    changes = sbom_diff.diff({"gone": "1.0"}, {"new": "2.0"})
    assert {(c.name, c.kind) for c in changes} == {("gone", "removed"), ("new", "added")}


def test_diff_detects_an_upgrade() -> None:
    (change,) = sbom_diff.diff({"urllib3": "2.0.0"}, {"urllib3": "2.7.0"})
    assert (change.kind, change.before, change.after) == ("upgraded", "2.0.0", "2.7.0")


def test_diff_detects_a_downgrade() -> None:
    """A silent downgrade is how a patched dependency gets un-patched."""
    (change,) = sbom_diff.diff({"openssl": "3.0.20"}, {"openssl": "3.0.19"})
    assert change.kind == "downgraded"


def test_diff_compares_versions_numerically_not_lexicographically() -> None:
    (change,) = sbom_diff.diff({"pkg": "1.9.0"}, {"pkg": "1.10.0"})
    assert change.kind == "upgraded"


def test_diff_treats_an_unparseable_version_change_as_an_upgrade() -> None:
    (change,) = sbom_diff.diff({"pkg": "2024-alpha"}, {"pkg": "2025-beta"})
    assert change.kind == "upgraded"


def test_diff_is_empty_when_nothing_moved() -> None:
    assert sbom_diff.diff({"a": "1"}, {"a": "1"}) == []


def test_diff_output_is_sorted_and_stable() -> None:
    changes = sbom_diff.diff({}, {"zlib": "1", "acme": "1", "middle": "1"})
    assert [c.name for c in changes] == ["acme", "middle", "zlib"]


def test_render_markdown_says_so_when_nothing_changed() -> None:
    assert "No dependency changes" in sbom_diff.render_markdown([], "old", "new")


def test_render_markdown_leads_with_the_headline() -> None:
    changes = sbom_diff.diff({"a": "1.0"}, {"a": "2.0", "b": "1.0"})
    rendered = sbom_diff.render_markdown(changes, "old", "new")
    assert "1 added, 1 upgraded" in rendered
    assert "| `b` | added |" in rendered


def test_main_writes_markdown_and_json(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    before = write_sbom(tmp_path / "before.json", [{"name": "a", "version": "1.0"}])
    after = write_sbom(
        tmp_path / "after.json",
        [{"name": "a", "version": "2.0"}, {"name": "b", "version": "1.0"}],
    )
    summary = tmp_path / "summary.md"
    out = tmp_path / "diff.md"
    monkeypatch.setenv("GITHUB_STEP_SUMMARY", str(summary))

    assert (
        sbom_diff.main(
            ["--before", str(before), "--after", str(after), "--json", "--markdown-out", str(out)]
        )
        == 0
    )
    payload = json.loads(capsys.readouterr().out)
    assert payload["before_count"] == 1 and payload["after_count"] == 2
    assert len(payload["changes"]) == 2
    assert "SBOM diff" in out.read_text(encoding="utf-8")
    assert "SBOM diff" in summary.read_text(encoding="utf-8")


def test_main_fails_when_more_components_are_added_than_allowed(tmp_path: Path) -> None:
    before = write_sbom(tmp_path / "before.json", [])
    after = write_sbom(
        tmp_path / "after.json",
        [{"name": n, "version": "1"} for n in ("a", "b", "c")],
    )
    assert sbom_diff.main(["--before", str(before), "--after", str(after), "--max-added", "2"]) == 4


def test_main_allows_additions_within_the_threshold(tmp_path: Path) -> None:
    before = write_sbom(tmp_path / "before.json", [])
    after = write_sbom(tmp_path / "after.json", [{"name": "a", "version": "1"}])
    assert sbom_diff.main(["--before", str(before), "--after", str(after), "--max-added", "2"]) == 0


def test_main_reports_an_unreadable_file(tmp_path: Path) -> None:
    after = write_sbom(tmp_path / "after.json", [])
    assert sbom_diff.main(["--before", str(tmp_path / "missing.json"), "--after", str(after)]) == 1
