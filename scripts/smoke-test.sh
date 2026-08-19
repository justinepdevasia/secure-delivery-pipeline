#!/usr/bin/env bash
#
# smoke-test.sh — prove the deployed service actually serves traffic, from inside
# the cluster, through the Service. A rollout completing only means the pods
# started; this is what says they work.
#
# Assertions are on status code and JSON shape via `jq -e`, never on a substring
# of human-readable output.
#
# Exit codes: 0 all checks passed | 1 a required tool is missing | 2 usage error
#             3 the service never became reachable | 4 an assertion failed

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

readonly CURL_IMAGE="curlimages/curl:8.11.1"

usage() {
  cat <<'EOF'
Usage: smoke-test.sh --service NAME [options]

Runs a throwaway curl pod inside the cluster and asserts on /healthz and
/api/v1/orders — status code and JSON shape.

Options:
  --service NAME     Service to target. Required.
  --namespace NAME   Namespace. Default default
  --port PORT        Service port. Default 80
  --timeout SECONDS  How long to wait for the service to answer. Default 120
  --json             Emit a JSON report on stdout.
  -h, --help         Show this help and exit 0.

Exit codes:
  0  every check passed
  1  a required tool is missing
  2  usage error
  3  the service never became reachable
  4  an assertion failed

Example:
  smoke-test.sh --service api-api --namespace default --json
EOF
}

# in_cluster_curl URL EXTRA... — run curl from a throwaway pod, print its output.
in_cluster_curl() {
  local name="smoke-$RANDOM"
  kubectl run "$name" \
    --namespace "$NAMESPACE" \
    --image "$CURL_IMAGE" \
    --restart=Never \
    --rm --attach --quiet \
    --command -- curl --silent --show-error --max-time 10 "$@"
}

main() {
  local service="" port=80 timeout=120 json=false
  NAMESPACE="default"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --service)
        [[ $# -ge 2 ]] || die "--service requires an argument" "$EX_USAGE"
        service="$2"
        shift 2
        ;;
      --namespace)
        [[ $# -ge 2 ]] || die "--namespace requires an argument" "$EX_USAGE"
        NAMESPACE="$2"
        shift 2
        ;;
      --port)
        [[ $# -ge 2 ]] || die "--port requires an argument" "$EX_USAGE"
        port="$2"
        shift 2
        ;;
      --timeout)
        [[ $# -ge 2 ]] || die "--timeout requires an argument" "$EX_USAGE"
        timeout="$2"
        shift 2
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

  [[ -n "$service" ]] || {
    usage >&2
    die "--service is required" "$EX_USAGE"
  }
  export NAMESPACE

  require_cmd kubectl jq

  local base="http://${service}.${NAMESPACE}.svc.cluster.local:${port}"
  local -a results=()
  local failures=0

  # 1. Reachability, with backoff — the Service may exist before endpoints do.
  # Attempts are derived from --timeout so the budget is honoured rather than
  # being a flag nobody reads.
  local attempts=$((timeout / 20))
  ((attempts >= 3)) || attempts=3
  log_info "waiting up to ~${timeout}s (${attempts} attempts) for ${base}/healthz"
  if ! RETRY_BASE_DELAY=2 retry_with_backoff "$attempts" \
    bash -c "kubectl run smoke-ready-\$RANDOM --namespace '${NAMESPACE}' --image '${CURL_IMAGE}' \
      --restart=Never --rm --attach --quiet --command -- \
      curl --silent --fail --max-time 10 '${base}/healthz' >/dev/null"; then
    log_error "service never answered within the retry budget"
    if [[ "$json" == true ]]; then
      printf '{"ok":false,"reason":"unreachable","service":"%s"}\n' "$(json_escape "$service")"
    fi
    exit "$EX_TIMEOUT"
  fi

  # 2. /healthz returns 200 and {"status":"ok"}.
  local body
  body="$(in_cluster_curl "${base}/healthz" || true)"
  if printf '%s' "$body" | jq -e '.status == "ok"' >/dev/null 2>&1; then
    log_info "healthz: ok"
    results+=('{"check":"healthz","status":"pass"}')
  else
    log_error "healthz did not return {\"status\":\"ok\"}: ${body}"
    results+=('{"check":"healthz","status":"fail"}')
    failures=$((failures + 1))
  fi

  # 3. /readyz reports a resolved configuration source.
  body="$(in_cluster_curl "${base}/readyz" || true)"
  if printf '%s' "$body" | jq -e '.status == "ready" and (.secrets_source | length > 0)' >/dev/null 2>&1; then
    log_info "readyz: ready, secrets_source=$(printf '%s' "$body" | jq -r .secrets_source)"
    results+=('{"check":"readyz","status":"pass"}')
  else
    log_error "readyz did not report ready: ${body}"
    results+=('{"check":"readyz","status":"fail"}')
    failures=$((failures + 1))
  fi

  # 4. The orders envelope has the documented shape, not merely a 200.
  body="$(in_cluster_curl "${base}/api/v1/orders" || true)"
  if printf '%s' "$body" | jq -e '
        (.count | type == "number")
        and (.items | type == "array")
        and (.count == (.items | length))
        and (.items | all(has("id") and has("total_cents") and has("status")))
      ' >/dev/null 2>&1; then
    log_info "orders: $(printf '%s' "$body" | jq -r .count) item(s), shape valid"
    results+=('{"check":"orders","status":"pass"}')
  else
    log_error "orders payload did not match the expected shape: ${body}"
    results+=('{"check":"orders","status":"fail"}')
    failures=$((failures + 1))
  fi

  # 5. A malformed order must be rejected, not accepted.
  local code
  code="$(in_cluster_curl --output /dev/null --write-out '%{http_code}' \
    -X POST -H 'Content-Type: application/json' \
    -d '{"customer_id":"nope","items":[]}' "${base}/api/v1/orders" || true)"
  if [[ "$code" == "422" ]]; then
    log_info "validation: malformed order rejected with 422"
    results+=('{"check":"validation","status":"pass"}')
  else
    log_error "malformed order returned ${code}, expected 422"
    results+=('{"check":"validation","status":"fail"}')
    failures=$((failures + 1))
  fi

  if [[ "$json" == true ]]; then
    printf '{"ok":%s,"service":"%s","failures":%d,"checks":[%s]}\n' \
      "$([[ $failures -eq 0 ]] && echo true || echo false)" \
      "$(json_escape "$service")" "$failures" \
      "$(
        IFS=,
        echo "${results[*]}"
      )"
  fi

  if ((failures > 0)); then
    log_error "${failures} smoke check(s) failed"
    exit "$EX_VERIFY"
  fi
  log_info "smoke test passed against ${base}"
}

main "$@"
