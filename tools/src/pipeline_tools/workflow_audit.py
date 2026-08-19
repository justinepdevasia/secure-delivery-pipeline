"""Static checks on workflow YAML that the off-the-shelf linters do not make.

actionlint catches syntax and expression errors; zizmor catches a broad class of
security smells. These three checks are the ones this repository treats as
non-negotiable, so they are enforced by code that lives in the repository:

  * every job declares an explicit ``permissions`` block
  * ``pull_request_target`` never checks out an untrusted ref
  * attacker-controlled context is never interpolated straight into ``run:``

Exit codes: 0 clean | 1 findings | 2 usage error
"""

from __future__ import annotations

import argparse
import logging
import os
import re
import sys
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

import yaml

from .cli import EX_FAIL, EX_OK, EX_USAGE, configure_logging, emit_json, write_step_summary

LOGGER = logging.getLogger("workflow_audit")

# Contexts an attacker can set on a pull request. Interpolating any of these into
# a shell command is remote code execution on the runner.
UNTRUSTED_PATTERN = re.compile(
    r"\$\{\{\s*(?:github\.event\.(?:issue|pull_request|comment|review|discussion)"
    r"[\w.]*\.(?:body|title)"
    r"|github\.event\.head_commit\.message"
    r"|github\.head_ref"
    r"|github\.event\.pull_request\.head\.(?:ref|label)"
    r")\s*\}\}"
)

# Refs that resolve to the PR's own (untrusted) code.
UNTRUSTED_REFS = (
    "github.event.pull_request.head.sha",
    "github.event.pull_request.head.ref",
    "github.event.pull_request.merge_commit_sha",
    "github.head_ref",
    "refs/pull/",
)


@dataclass(frozen=True)
class Finding:
    """One rule violation, addressed to whoever has to fix it."""

    file: str
    job: str
    rule: str
    detail: str


def _jobs(document: dict[str, Any]) -> dict[str, Any]:
    jobs = document.get("jobs")
    return jobs if isinstance(jobs, dict) else {}


def _triggers(document: dict[str, Any]) -> set[str]:
    # PyYAML parses the bare key `on:` as the boolean True.
    untyped: dict[Any, Any] = document
    raw = untyped.get("on", untyped.get(True))
    if isinstance(raw, str):
        return {raw}
    if isinstance(raw, list):
        return {str(item) for item in raw}
    if isinstance(raw, dict):
        return {str(key) for key in raw}
    return set()


def check_permissions(path: Path, document: dict[str, Any]) -> list[Finding]:
    """Every job must declare permissions, or inherit an explicit top-level block."""
    top_level = "permissions" in document
    findings: list[Finding] = []
    for name, job in _jobs(document).items():
        if not isinstance(job, dict):
            continue
        if "permissions" in job:
            continue
        # A job that calls a reusable workflow inherits the caller's permissions,
        # but only an explicit top-level block makes that inheritance reviewable.
        if not top_level:
            findings.append(
                Finding(
                    file=str(path),
                    job=str(name),
                    rule="explicit-permissions",
                    detail="job declares no permissions and the workflow has no top-level block",
                )
            )
    return findings


def check_pull_request_target(path: Path, document: dict[str, Any]) -> list[Finding]:
    """pull_request_target runs with a write token; it must not check out PR code."""
    if "pull_request_target" not in _triggers(document):
        return []

    findings: list[Finding] = []
    for name, job in _jobs(document).items():
        if not isinstance(job, dict):
            continue
        for step in job.get("steps") or []:
            if not isinstance(step, dict):
                continue
            if "checkout" not in str(step.get("uses", "")):
                continue
            ref = str((step.get("with") or {}).get("ref", ""))
            if any(untrusted in ref for untrusted in UNTRUSTED_REFS):
                findings.append(
                    Finding(
                        file=str(path),
                        job=str(name),
                        rule="pull-request-target-checkout",
                        detail=f"pull_request_target checks out an untrusted ref: {ref}",
                    )
                )
    return findings


def check_untrusted_interpolation(path: Path, document: dict[str, Any]) -> list[Finding]:
    """Attacker-controlled text must reach a script through env, never through run:."""
    findings: list[Finding] = []
    for name, job in _jobs(document).items():
        if not isinstance(job, dict):
            continue
        for step in job.get("steps") or []:
            if not isinstance(step, dict):
                continue
            run = step.get("run")
            if not isinstance(run, str):
                continue
            for match in UNTRUSTED_PATTERN.finditer(run):
                findings.append(
                    Finding(
                        file=str(path),
                        job=str(name),
                        rule="untrusted-interpolation",
                        detail=f"attacker-controlled context in run: {match.group(0)}",
                    )
                )
    return findings


CHECKS = (check_permissions, check_pull_request_target, check_untrusted_interpolation)


def audit_file(path: Path) -> list[Finding]:
    """Run every check against one workflow file."""
    try:
        document = yaml.safe_load(path.read_text(encoding="utf-8"))
    except yaml.YAMLError as exc:
        return [Finding(str(path), "-", "unparseable", f"YAML error: {exc}")]

    if not isinstance(document, dict):
        return [Finding(str(path), "-", "unparseable", "workflow is not a YAML mapping")]

    return [finding for check in CHECKS for finding in check(path, document)]


def discover(paths: list[str]) -> list[Path]:
    """Expand directories into the workflow files inside them."""
    found: list[Path] = []
    for raw in paths:
        candidate = Path(raw)
        if candidate.is_dir():
            found.extend(sorted(candidate.glob("*.yml")) + sorted(candidate.glob("*.yaml")))
        elif candidate.is_file():
            found.append(candidate)
    return found


def render_markdown(findings: list[Finding], scanned: int) -> str:
    """Step-summary table. A green result should say so, not stay silent."""
    if not findings:
        return f"### Workflow audit\n\n{scanned} workflow(s) scanned — no findings.\n"
    rows = "\n".join(f"| `{f.file}` | `{f.job}` | {f.rule} | {f.detail} |" for f in findings)
    return (
        "### Workflow audit\n\n"
        f"{len(findings)} finding(s) across {scanned} workflow(s).\n\n"
        "| file | job | rule | detail |\n| --- | --- | --- | --- |\n" + rows + "\n"
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="workflow-audit",
        description="Audit GitHub Actions workflows for permissions and injection risks.",
        epilog="Exit codes: 0 clean, 1 findings, 2 usage error.",
    )
    parser.add_argument("paths", nargs="+", help="Workflow files or directories to audit")
    parser.add_argument("--json", action="store_true", help="Emit findings as JSON on stdout")
    parser.add_argument("--verbose", action="store_true", help="Debug logging on stderr")
    args = parser.parse_args(argv)

    configure_logging(args.verbose)

    files = discover(args.paths)
    if not files:
        LOGGER.error("no workflow files found in: %s", ", ".join(args.paths))
        return EX_USAGE

    findings = [finding for path in files for finding in audit_file(path)]

    for finding in findings:
        LOGGER.error("%s [%s] %s: %s", finding.file, finding.job, finding.rule, finding.detail)

    if args.json:
        emit_json(
            {
                "ok": not findings,
                "scanned": len(files),
                "findings": [asdict(f) for f in findings],
            }
        )

    write_step_summary(render_markdown(findings, len(files)), os.getenv("GITHUB_STEP_SUMMARY"))

    if findings:
        LOGGER.error("%d workflow finding(s)", len(findings))
        return EX_FAIL
    LOGGER.info("%d workflow(s) audited, no findings", len(files))
    return EX_OK


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
