"""Diff two CycloneDX SBOMs and say what changed.

Generating an SBOM and attaching it to a release produces a file nobody opens.
Diffing it against the previous build turns it into a control that speaks up:
"this pull request adds 3 dependencies and upgrades openssl" is a review comment
someone acts on.

Exit codes: 0 diffed | 1 a file could not be read | 2 usage error
             4 a policy threshold was exceeded
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import sys
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

from .cli import (
    EX_FAIL,
    EX_OK,
    EX_VERIFY,
    configure_logging,
    emit_json,
    write_step_summary,
)

LOGGER = logging.getLogger("sbom_diff")


@dataclass(frozen=True)
class Change:
    """One dependency that appeared, disappeared or moved."""

    name: str
    kind: str  # added | removed | upgraded | downgraded
    before: str = ""
    after: str = ""


def load_components(path: Path) -> dict[str, str]:
    """Read a CycloneDX document into {name: version}.

    Components are keyed by group/name so two packages that share a short name in
    different ecosystems are not conflated.
    """
    document: Any = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(document, dict):
        raise ValueError(f"{path} is not a CycloneDX document")

    components: dict[str, str] = {}
    for component in document.get("components") or []:
        if not isinstance(component, dict):
            continue
        name = str(component.get("name", "")).strip()
        if not name:
            continue
        group = str(component.get("group", "")).strip()
        key = f"{group}/{name}" if group else name
        components[key] = str(component.get("version", "")).strip()
    return components


def _version_key(version: str) -> tuple[int, ...] | None:
    """Numeric comparison key, or None when the version is not dotted-numeric."""
    parts = version.split("-")[0].split(".")
    if not all(part.isdigit() for part in parts if part):
        return None
    return tuple(int(part) for part in parts if part)


def diff(before: dict[str, str], after: dict[str, str]) -> list[Change]:
    """Compare two component maps. Sorted, so the output is stable across runs."""
    changes: list[Change] = []

    for name in sorted(set(after) - set(before)):
        changes.append(Change(name=name, kind="added", after=after[name]))
    for name in sorted(set(before) - set(after)):
        changes.append(Change(name=name, kind="removed", before=before[name]))

    for name in sorted(set(before) & set(after)):
        old, new = before[name], after[name]
        if old == new:
            continue
        old_key, new_key = _version_key(old), _version_key(new)
        # An unparseable version is reported as an upgrade rather than guessed at.
        kind = "upgraded"
        if old_key is not None and new_key is not None and new_key < old_key:
            kind = "downgraded"
        changes.append(Change(name=name, kind=kind, before=old, after=new))

    return changes


def render_markdown(changes: list[Change], before_label: str, after_label: str) -> str:
    """A PR comment worth reading: the headline first, the table second."""
    if not changes:
        return (
            "### SBOM diff\n\n"
            f"No dependency changes between `{before_label}` and `{after_label}`.\n"
        )

    counts: dict[str, int] = {}
    for change in changes:
        counts[change.kind] = counts.get(change.kind, 0) + 1
    headline = ", ".join(f"{count} {kind}" for kind, count in sorted(counts.items()))

    rows = "\n".join(
        f"| `{c.name}` | {c.kind} | {c.before or '—'} | {c.after or '—'} |" for c in changes
    )
    return (
        "### SBOM diff\n\n"
        f"**{headline}** between `{before_label}` and `{after_label}`.\n\n"
        "| component | change | before | after |\n| --- | --- | --- | --- |\n"
        f"{rows}\n"
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="sbom-diff",
        description="Diff two CycloneDX SBOMs and report added, removed and upgraded components.",
        epilog="Exit codes: 0 diffed, 1 unreadable input, 2 usage error, 4 threshold exceeded.",
    )
    parser.add_argument("--before", required=True, help="Baseline CycloneDX JSON")
    parser.add_argument("--after", required=True, help="New CycloneDX JSON")
    parser.add_argument("--before-label", default="previous")
    parser.add_argument("--after-label", default="this build")
    parser.add_argument(
        "--max-added",
        type=int,
        default=-1,
        help="Fail with exit 4 if more than this many components are added. -1 disables.",
    )
    parser.add_argument("--markdown-out", help="Write the Markdown report here")
    parser.add_argument("--json", action="store_true", help="Emit the diff as JSON on stdout")
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args(argv)

    configure_logging(args.verbose)

    try:
        before = load_components(Path(args.before))
        after = load_components(Path(args.after))
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        LOGGER.error("could not read an SBOM: %s", exc)
        return EX_FAIL

    changes = diff(before, after)
    markdown = render_markdown(changes, args.before_label, args.after_label)

    for change in changes:
        LOGGER.info("%s %s %s -> %s", change.kind, change.name, change.before, change.after)
    LOGGER.info("%d component change(s)", len(changes))

    if args.markdown_out:
        Path(args.markdown_out).write_text(markdown, encoding="utf-8")
    write_step_summary(markdown, os.getenv("GITHUB_STEP_SUMMARY"))

    if args.json:
        emit_json(
            {
                "ok": True,
                "before_count": len(before),
                "after_count": len(after),
                "changes": [asdict(c) for c in changes],
            }
        )

    added = sum(1 for c in changes if c.kind == "added")
    if args.max_added >= 0 and added > args.max_added:
        LOGGER.error("%d components added, more than the %d allowed", added, args.max_added)
        return EX_VERIFY
    return EX_OK


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
