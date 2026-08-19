#!/usr/bin/env bash
#
# collect-diagnostics.sh — gather everything needed to explain a failed deploy
# into one tarball, so `upload-artifact` can carry it out of the runner.
#
# Nothing here is allowed to fail the script: this runs when something has
# already gone wrong, and a diagnostic collector that aborts halfway is worse
# than no collector at all.
#
# Exit codes: 0 bundle written | 1 a required tool is missing | 2 usage error

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
  cat <<'EOF'
Usage: collect-diagnostics.sh [--namespace NAME] [--out DIR] [--no-archive] [--help]

Collects, for the given namespace: pod/deployment/replicaset/service/event
listings, `kubectl describe` for every pod, container logs (current and
previous), the Helm release history, and the emulator's own container log.

Options:
  --namespace NAME   Namespace to collect from. Default default
  --out DIR          Output directory. Default diagnostics
  --release NAME     Helm release to include history for. Default api
  --no-archive       Leave the directory rather than producing a tarball.
  -h, --help         Show this help and exit 0.

Exit codes:
  0  a bundle was written (individual collectors may still have failed)
  1  a required tool is missing
  2  usage error
EOF
}

# capture FILE COMMAND... — run a collector, never let it abort the script.
capture() {
  local file="$1"
  shift
  {
    printf '$ %s\n\n' "$*"
    "$@" 2>&1 || printf '\n(collector exited %d)\n' "$?"
  } >"$file"
}

main() {
  local namespace="default" out="diagnostics" release="api" archive=true

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --namespace)
        [[ $# -ge 2 ]] || die "--namespace requires an argument" "$EX_USAGE"
        namespace="$2"
        shift 2
        ;;
      --out)
        [[ $# -ge 2 ]] || die "--out requires an argument" "$EX_USAGE"
        out="$2"
        shift 2
        ;;
      --release)
        [[ $# -ge 2 ]] || die "--release requires an argument" "$EX_USAGE"
        release="$2"
        shift 2
        ;;
      --no-archive)
        archive=false
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

  require_cmd kubectl

  mkdir -p "${out}/pods"
  log_info "collecting diagnostics for namespace ${namespace} into ${out}"

  capture "${out}/nodes.txt" kubectl get nodes -o wide
  capture "${out}/all.txt" kubectl get all --namespace "$namespace" -o wide
  capture "${out}/events.txt" kubectl get events --namespace "$namespace" \
    --sort-by=.lastTimestamp
  capture "${out}/deployments.yaml" kubectl get deployments --namespace "$namespace" -o yaml
  capture "${out}/replicasets.txt" kubectl get replicasets --namespace "$namespace" -o wide
  capture "${out}/endpoints.txt" kubectl get endpoints --namespace "$namespace"

  local pod
  while read -r pod; do
    [[ -n "$pod" ]] || continue
    capture "${out}/pods/${pod}.describe.txt" kubectl describe pod "$pod" --namespace "$namespace"
    capture "${out}/pods/${pod}.log" kubectl logs "$pod" --namespace "$namespace" --all-containers
    # The previous container's log is the one that explains a CrashLoopBackOff.
    capture "${out}/pods/${pod}.previous.log" kubectl logs "$pod" --namespace "$namespace" \
      --all-containers --previous
  done < <(kubectl get pods --namespace "$namespace" -o name 2>/dev/null | cut -d/ -f2 || true)

  if command -v helm >/dev/null 2>&1; then
    capture "${out}/helm-history.txt" helm history "$release" --namespace "$namespace"
    capture "${out}/helm-values.yaml" helm get values "$release" --namespace "$namespace"
    capture "${out}/helm-manifest.yaml" helm get manifest "$release" --namespace "$namespace"
  fi

  if command -v docker >/dev/null 2>&1; then
    capture "${out}/floci.log" docker logs floci
    capture "${out}/containers.txt" docker ps -a
  fi

  if [[ "$archive" == true ]]; then
    require_cmd tar
    tar -czf "${out}.tar.gz" "$out"
    log_info "wrote ${out}.tar.gz"
  else
    log_info "wrote ${out}/"
  fi
}

main "$@"
