#!/usr/bin/env bash
#
# Shared helpers for every script in scripts/. Source it, never execute it:
#
#   # shellcheck source=scripts/lib/common.sh
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
#
# Logging goes to stderr so stdout stays machine-parseable (--json modes).
#
# Exit codes shared by all scripts in this repository:
#   0  success
#   1  generic failure
#   2  usage error
#   3  timeout
#   4  verification failure

if [[ -n "${COMMON_SH_SOURCED:-}" ]]; then
  return 0
fi
COMMON_SH_SOURCED=1

# shellcheck disable=SC2034  # consumed by the scripts that source this file
readonly EX_OK=0
readonly EX_FAIL=1
# shellcheck disable=SC2034
readonly EX_USAGE=2
# shellcheck disable=SC2034
readonly EX_TIMEOUT=3
# shellcheck disable=SC2034
readonly EX_VERIFY=4

# Seconds between the first and second retry attempt. Tests set this to 0.
: "${RETRY_BASE_DELAY:=1}"

_log() {
  local level="$1"
  shift
  printf '%s [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$level" "$*" >&2
}

log_info() { _log INFO "$@"; }
log_warn() { _log WARN "$@"; }
log_error() { _log ERROR "$@"; }

# die MESSAGE [EXIT_CODE]
die() {
  local message="$1"
  local code="${2:-$EX_FAIL}"
  log_error "$message"
  exit "$code"
}

# require_cmd CMD...  — fail fast with a message naming every missing tool.
require_cmd() {
  local missing=()
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if ((${#missing[@]} > 0)); then
    die "missing required command(s): ${missing[*]}" "$EX_FAIL"
  fi
}

# retry_with_backoff MAX_ATTEMPTS COMMAND...
# Exponential backoff starting at $RETRY_BASE_DELAY, doubling each attempt.
# Returns the exit status of the final attempt.
retry_with_backoff() {
  local max_attempts="$1"
  shift
  local attempt=1
  local delay="$RETRY_BASE_DELAY"
  local status=0

  while ((attempt <= max_attempts)); do
    # `|| status=$?` both captures the real exit status and shields it from set -e;
    # `if cmd; then` would leave $? as 0 when the condition fails.
    status=0
    "$@" || status=$?
    if ((status == 0)); then
      return 0
    fi
    if ((attempt == max_attempts)); then
      log_error "command failed after ${attempt} attempt(s): $*"
      return "$status"
    fi
    log_warn "attempt ${attempt}/${max_attempts} failed (status ${status}), retrying in ${delay}s"
    sleep "$delay"
    delay=$((delay * 2))
    attempt=$((attempt + 1))
  done

  return "$status"
}

# json_escape STRING — minimal JSON string escaping, so --json output needs no jq.
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

# make_scratch_dir — mktemp -d that the caller's `trap cleanup EXIT` removes.
make_scratch_dir() {
  mktemp -d "${TMPDIR:-/tmp}/sdp.XXXXXXXX"
}
