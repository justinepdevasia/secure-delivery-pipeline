"""Minimal HTTP client: timeouts and bounded retries, on the standard library.

A pipeline tool that hangs on a slow API is a stuck job holding a runner. Every
call here has a timeout, and retries only the statuses worth retrying.

Deliberately not `requests`: this package would then carry a dependency, and its
transitive tree, into a repository whose whole subject is dependency risk.
"""

from __future__ import annotations

import json
import logging
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from typing import Any

LOGGER = logging.getLogger("httpc")

RETRYABLE_STATUS = frozenset({429, 500, 502, 503, 504})

# urllib happily opens file:// and ftp://. A tool that takes a URL from the
# environment must not be talked into reading a local file.
ALLOWED_SCHEMES = frozenset({"http", "https"})


class HttpError(RuntimeError):
    """A request failed in a way retrying will not fix."""

    def __init__(self, status: int, url: str, body: str) -> None:
        super().__init__(f"{status} from {url}: {body[:200]}")
        self.status = status
        self.url = url
        self.body = body


@dataclass(frozen=True)
class Response:
    status: int
    body: bytes

    def json(self) -> Any:
        return json.loads(self.body or b"null")


def request(
    url: str,
    *,
    method: str = "GET",
    headers: dict[str, str] | None = None,
    body: bytes | None = None,
    timeout: float = 15.0,
    attempts: int = 3,
    backoff: float = 1.0,
) -> Response:
    """Perform an HTTP request, retrying only what is worth retrying."""
    scheme = urllib.parse.urlparse(url).scheme.lower()
    if scheme not in ALLOWED_SCHEMES:
        raise ValueError(f"refusing to request a {scheme or 'schemeless'} URL: {url}")

    last: Exception | None = None

    for attempt in range(1, attempts + 1):
        # noqa justified above: the scheme is validated before we get here.
        req = urllib.request.Request(url, data=body, method=method)  # noqa: S310
        for key, value in (headers or {}).items():
            req.add_header(key, value)

        try:
            with urllib.request.urlopen(req, timeout=timeout) as response:  # noqa: S310
                return Response(status=response.status, body=response.read())
        except urllib.error.HTTPError as exc:
            payload = exc.read().decode("utf-8", "replace")
            if exc.code not in RETRYABLE_STATUS or attempt == attempts:
                raise HttpError(exc.code, url, payload) from exc
            LOGGER.warning("attempt %d/%d: %s returned %d", attempt, attempts, url, exc.code)
            last = exc
        except (urllib.error.URLError, TimeoutError) as exc:
            if attempt == attempts:
                raise
            LOGGER.warning("attempt %d/%d: %s failed: %s", attempt, attempts, url, exc)
            last = exc

        time.sleep(backoff * (2 ** (attempt - 1)))

    raise RuntimeError(f"unreachable retry state for {url}") from last


def get_json(url: str, *, token: str | None = None, **kwargs: Any) -> Any:
    """GET and decode JSON, with a GitHub-shaped Authorization header when given."""
    headers: dict[str, str] = {"Accept": "application/json", "User-Agent": "pipeline-tools"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    headers.update(kwargs.pop("headers", {}))
    return request(url, headers=headers, **kwargs).json()
