#!/usr/bin/env bash
#
# wait-for-endpoint.sh — poll an HTTP endpoint until it answers, then exit 0.
#
# Used to gate every step that follows a service start (the AWS emulator, a port
# forward, a smoke-test target). Never `sleep 30 && hope`.
#
# Exit codes: 0 endpoint healthy | 2 usage error | 3 timed out

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
  cat <<'EOF'
Usage: wait-for-endpoint.sh --url URL [options]

Polls URL until it returns the expected HTTP status, using exponential backoff
capped at --max-interval.

Options:
  --url URL              Endpoint to poll. Required.
  --timeout SECONDS      Give up after this long. Default 90.
  --expect-status CODE   HTTP status that counts as healthy. Default 200.
  --interval SECONDS     Initial delay between attempts. Default 1.
  --max-interval SECONDS Cap on the backoff delay. Default 8.
  --json                 Emit a JSON result on stdout.
  -h, --help             Show this help and exit 0.

Exit codes:
  0  endpoint returned the expected status
  2  usage error
  3  timed out

Example:
  wait-for-endpoint.sh --url http://localhost:4566/_localstack/health --timeout 120
EOF
}

# probe URL — prints the HTTP status code, or 000 when the request failed outright.
probe() {
  curl --silent --show-error --output /dev/null --max-time 5 \
    --write-out '%{http_code}' "$1" 2>/dev/null || printf '000'
}

main() {
  local url="" timeout=90 expect=200 interval=1 max_interval=8 json=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --url)
        [[ $# -ge 2 ]] || die "--url requires an argument" "$EX_USAGE"
        url="$2"
        shift 2
        ;;
      --url=*)
        url="${1#*=}"
        shift
        ;;
      --timeout)
        [[ $# -ge 2 ]] || die "--timeout requires an argument" "$EX_USAGE"
        timeout="$2"
        shift 2
        ;;
      --timeout=*)
        timeout="${1#*=}"
        shift
        ;;
      --expect-status)
        [[ $# -ge 2 ]] || die "--expect-status requires an argument" "$EX_USAGE"
        expect="$2"
        shift 2
        ;;
      --expect-status=*)
        expect="${1#*=}"
        shift
        ;;
      --interval)
        [[ $# -ge 2 ]] || die "--interval requires an argument" "$EX_USAGE"
        interval="$2"
        shift 2
        ;;
      --interval=*)
        interval="${1#*=}"
        shift
        ;;
      --max-interval)
        [[ $# -ge 2 ]] || die "--max-interval requires an argument" "$EX_USAGE"
        max_interval="$2"
        shift 2
        ;;
      --max-interval=*)
        max_interval="${1#*=}"
        shift
        ;;
      --json)
        json=true
        shift
        ;;
      -h | --help)
        usage
        exit "$EX_OK"
        ;;
      *)
        usage >&2
        die "unknown argument: $1" "$EX_USAGE"
        ;;
    esac
  done

  [[ -n "$url" ]] || {
    usage >&2
    die "--url is required" "$EX_USAGE"
  }
  [[ "$timeout" =~ ^[0-9]+$ ]] || die "--timeout must be a whole number of seconds" "$EX_USAGE"

  require_cmd curl

  local start elapsed attempts=0 code=000
  start="$(date +%s)"

  while :; do
    attempts=$((attempts + 1))
    code="$(probe "$url")"
    elapsed=$(($(date +%s) - start))

    if [[ "$code" == "$expect" ]]; then
      log_info "endpoint healthy after ${attempts} attempt(s), ${elapsed}s: ${url}"
      if [[ "$json" == true ]]; then
        printf '{"ok":true,"url":"%s","status":"%s","attempts":%d,"elapsed_seconds":%d}\n' \
          "$(json_escape "$url")" "$code" "$attempts" "$elapsed"
      fi
      return "$EX_OK"
    fi

    if ((elapsed >= timeout)); then
      log_error "timed out after ${elapsed}s waiting for ${url} (last status ${code})"
      if [[ "$json" == true ]]; then
        printf '{"ok":false,"url":"%s","status":"%s","attempts":%d,"elapsed_seconds":%d}\n' \
          "$(json_escape "$url")" "$code" "$attempts" "$elapsed"
      fi
      return "$EX_TIMEOUT"
    fi

    log_warn "attempt ${attempts}: ${url} returned ${code}, expected ${expect}; retrying in ${interval}s"
    sleep "$interval"
    interval=$((interval * 2))
    ((interval > max_interval)) && interval="$max_interval"
  done
}

main "$@"
