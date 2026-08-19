#!/usr/bin/env bash
#
# wait-for-rollout.sh — wrap `kubectl rollout status` so a failed rollout leaves
# evidence behind instead of just a non-zero exit code.
#
# On failure it calls collect-diagnostics.sh before exiting, because by the time
# anyone reads the log the pods are usually gone.
#
# Exit codes: 0 rolled out | 1 a required tool is missing | 2 usage error
#             3 the rollout did not complete in time

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
  cat <<'EOF'
Usage: wait-for-rollout.sh --deployment NAME [options]

Waits for a Deployment to finish rolling out. On timeout it gathers diagnostics
into a tarball first, then exits 3.

Options:
  --deployment NAME   Deployment to wait for. Required.
  --namespace NAME    Namespace. Default default
  --timeout SECONDS   How long to wait. Default 300
  --diagnostics DIR   Where collect-diagnostics.sh writes. Default diagnostics
  --no-diagnostics    Do not collect diagnostics on failure.
  --json              Emit a JSON result on stdout.
  -h, --help          Show this help and exit 0.

Exit codes:
  0  the rollout completed
  1  a required tool is missing
  2  usage error
  3  the rollout did not complete within --timeout

Example:
  wait-for-rollout.sh --deployment api-api --namespace default --timeout 300
EOF
}

main() {
  local deployment="" namespace="default" timeout=300
  local diagnostics="diagnostics" collect=true json=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --deployment)
        [[ $# -ge 2 ]] || die "--deployment requires an argument" "$EX_USAGE"
        deployment="$2"
        shift 2
        ;;
      --namespace)
        [[ $# -ge 2 ]] || die "--namespace requires an argument" "$EX_USAGE"
        namespace="$2"
        shift 2
        ;;
      --timeout)
        [[ $# -ge 2 ]] || die "--timeout requires an argument" "$EX_USAGE"
        timeout="$2"
        shift 2
        ;;
      --diagnostics)
        [[ $# -ge 2 ]] || die "--diagnostics requires an argument" "$EX_USAGE"
        diagnostics="$2"
        shift 2
        ;;
      --no-diagnostics)
        collect=false
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

  [[ -n "$deployment" ]] || {
    usage >&2
    die "--deployment is required" "$EX_USAGE"
  }
  [[ "$timeout" =~ ^[0-9]+$ ]] || die "--timeout must be a whole number of seconds" "$EX_USAGE"

  require_cmd kubectl

  local start elapsed status=ok
  start="$(date +%s)"

  log_info "waiting up to ${timeout}s for deployment/${deployment} in ${namespace}"
  if ! kubectl rollout status "deployment/${deployment}" \
    --namespace "$namespace" --timeout "${timeout}s"; then
    status=timeout
  fi
  elapsed=$(($(date +%s) - start))

  if [[ "$status" == timeout ]]; then
    log_error "deployment/${deployment} did not roll out within ${timeout}s"
    if [[ "$collect" == true ]]; then
      log_info "collecting diagnostics before exiting"
      "${SCRIPT_DIR}/collect-diagnostics.sh" --namespace "$namespace" --out "$diagnostics" || true
    fi
    if [[ "$json" == true ]]; then
      printf '{"ok":false,"deployment":"%s","namespace":"%s","elapsed_seconds":%d}\n' \
        "$(json_escape "$deployment")" "$(json_escape "$namespace")" "$elapsed"
    fi
    exit "$EX_TIMEOUT"
  fi

  log_info "deployment/${deployment} rolled out in ${elapsed}s"
  if [[ "$json" == true ]]; then
    printf '{"ok":true,"deployment":"%s","namespace":"%s","elapsed_seconds":%d}\n' \
      "$(json_escape "$deployment")" "$(json_escape "$namespace")" "$elapsed"
  fi
}

main "$@"
