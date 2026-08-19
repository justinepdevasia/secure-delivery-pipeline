"""Sticky pull request comments.

A bot that posts a fresh comment on every push buries the conversation. Each
comment here carries a hidden marker; a second run finds its own previous comment
and edits it, so a PR has exactly one SBOM comment however many times CI runs.

Exit codes: 0 posted | 1 the API call failed | 2 usage error
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import sys
from typing import Any

from .cli import EX_FAIL, EX_OK, EX_USAGE, configure_logging, emit_json
from .httpc import HttpError, get_json, request

LOGGER = logging.getLogger("pr_comment")

API = "https://api.github.com"


def marker(name: str) -> str:
    """The hidden HTML comment that identifies one bot's comment from another's."""
    return f"<!-- pipeline-tools:{name} -->"


def find_existing(repo: str, pr: int, name: str, token: str, *, api: str = API) -> int | None:
    """Return the id of this marker's previous comment, if there is one."""
    page = 1
    while True:
        comments: list[dict[str, Any]] = get_json(
            f"{api}/repos/{repo}/issues/{pr}/comments?per_page=100&page={page}",
            token=token,
        )
        if not comments:
            return None
        for comment in comments:
            if marker(name) in (comment.get("body") or ""):
                return int(comment["id"])
        if len(comments) < 100:
            return None
        page += 1


def post(repo: str, pr: int, name: str, body: str, token: str, *, api: str = API) -> dict[str, Any]:
    """Create or update the sticky comment. Returns the API's response."""
    payload = json.dumps({"body": f"{marker(name)}\n{body}"}).encode()
    headers = {
        "Accept": "application/vnd.github+json",
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
        "User-Agent": "pipeline-tools",
    }

    existing = find_existing(repo, pr, name, token, api=api)
    if existing is None:
        url = f"{api}/repos/{repo}/issues/{pr}/comments"
        method = "POST"
        LOGGER.info("creating a new %s comment on %s#%d", name, repo, pr)
    else:
        url = f"{api}/repos/{repo}/issues/comments/{existing}"
        method = "PATCH"
        LOGGER.info("updating comment %d on %s#%d", existing, repo, pr)

    response = request(url, method=method, headers=headers, body=payload)
    decoded: dict[str, Any] = json.loads(response.body)
    return decoded


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="pr-comment",
        description="Create or update a sticky pull request comment.",
        epilog="Exit codes: 0 posted, 1 API failure, 2 usage error.",
    )
    parser.add_argument("--repo", default=os.getenv("GITHUB_REPOSITORY"), help="owner/name")
    parser.add_argument("--pr", type=int, help="Pull request number")
    parser.add_argument("--name", required=True, help="Marker name, e.g. sbom-diff")
    parser.add_argument("--body-file", help="File holding the comment body; - for stdin")
    parser.add_argument("--body", help="Comment body as a literal string")
    parser.add_argument("--json", action="store_true", help="Emit the result as JSON")
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args(argv)

    configure_logging(args.verbose)

    token = os.getenv("GITHUB_TOKEN") or os.getenv("GH_TOKEN") or ""
    if not args.repo or not token:
        LOGGER.error("--repo and a GITHUB_TOKEN are both required")
        return EX_USAGE
    if args.pr is None:
        LOGGER.error("--pr is required")
        return EX_USAGE

    if args.body is not None:
        body = args.body
    elif args.body_file == "-":
        body = sys.stdin.read()
    elif args.body_file:
        with open(args.body_file, encoding="utf-8") as handle:
            body = handle.read()
    else:
        LOGGER.error("one of --body or --body-file is required")
        return EX_USAGE

    try:
        result = post(args.repo, args.pr, args.name, body, token)
    except HttpError as exc:
        LOGGER.error("could not post the comment: %s", exc)
        return EX_FAIL

    if args.json:
        emit_json({"ok": True, "id": result.get("id"), "url": result.get("html_url")})
    return EX_OK


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
