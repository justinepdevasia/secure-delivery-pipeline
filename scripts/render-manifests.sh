#!/usr/bin/env bash
#
# render-manifests.sh — render the chart for one values file and validate the
# result: kubeconform against vendored schemas, kube-linter, and this
# repository's own conftest policies.
#
# Rendering and validating live here rather than in YAML so the same command runs
# in CI, in a pre-commit hook, and in a bats test.
#
# Exit codes: 0 valid | 1 a required tool is missing | 2 usage error
#             4 a validation check failed

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

readonly DEFAULT_CHART="charts/api"
readonly DEFAULT_POLICY="policy"
readonly DEFAULT_SCHEMAS="schemas"

usage() {
  cat <<'EOF'
Usage: render-manifests.sh --values FILE [options]

Renders a Helm chart and validates the output. Every check runs; the script
reports all failures rather than stopping at the first.

Options:
  --chart DIR       Chart directory. Default charts/api
  --values FILE     Values file to render with. Required.
  --release NAME    Release name for the render. Default api
  --out FILE        Write the rendered manifest here. Default rendered-<values>.yaml
  --policy DIR      Conftest policy directory. Default policy
  --schemas DIR     Vendored CRD schema directory. Default schemas
  --skip CHECK      Skip a check: kubeconform, kube-linter or conftest. Repeatable.
  --json            Emit a JSON report on stdout.
  -h, --help        Show this help and exit 0.

Exit codes:
  0  chart renders and every check passes
  1  a required tool is missing
  2  usage error
  4  a validation check failed

Example:
  render-manifests.sh --values charts/api/values-prod.yaml --json
EOF
}

main() {
  local chart="$DEFAULT_CHART" values="" release="api" out=""
  local policy="$DEFAULT_POLICY" schemas="$DEFAULT_SCHEMAS" json=false
  local -a skip=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --chart)
        [[ $# -ge 2 ]] || die "--chart requires an argument" "$EX_USAGE"
        chart="$2"
        shift 2
        ;;
      --values)
        [[ $# -ge 2 ]] || die "--values requires an argument" "$EX_USAGE"
        values="$2"
        shift 2
        ;;
      --release)
        [[ $# -ge 2 ]] || die "--release requires an argument" "$EX_USAGE"
        release="$2"
        shift 2
        ;;
      --out)
        [[ $# -ge 2 ]] || die "--out requires an argument" "$EX_USAGE"
        out="$2"
        shift 2
        ;;
      --policy)
        [[ $# -ge 2 ]] || die "--policy requires an argument" "$EX_USAGE"
        policy="$2"
        shift 2
        ;;
      --schemas)
        [[ $# -ge 2 ]] || die "--schemas requires an argument" "$EX_USAGE"
        schemas="$2"
        shift 2
        ;;
      --skip)
        [[ $# -ge 2 ]] || die "--skip requires an argument" "$EX_USAGE"
        skip+=("$2")
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

  [[ -n "$values" ]] || {
    usage >&2
    die "--values is required" "$EX_USAGE"
  }
  [[ -f "$values" ]] || die "no such values file: ${values}" "$EX_USAGE"
  [[ -d "$chart" ]] || die "no such chart directory: ${chart}" "$EX_USAGE"

  require_cmd helm
  [[ -n "$out" ]] || out="rendered-$(basename "${values%.yaml}").yaml"

  log_info "rendering ${chart} with $(basename "$values")"
  helm template "$release" "$chart" --values "$values" >"$out"

  local -a results=()
  local failures=0 check status

  for check in kubeconform kube-linter conftest; do
    if [[ " ${skip[*]-} " == *" ${check} "* ]]; then
      log_warn "skipping ${check}"
      results+=("$(printf '{"check":"%s","status":"skipped"}' "$check")")
      continue
    fi

    require_cmd "$check"
    status=pass
    case "$check" in
      kubeconform)
        kubeconform -strict -summary \
          -schema-location default \
          -schema-location "${schemas}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json" \
          "$out" || status=fail
        ;;
      kube-linter)
        kube-linter lint "$out" || status=fail
        ;;
      conftest)
        conftest test --policy "$policy" --all-namespaces "$out" || status=fail
        ;;
    esac

    if [[ "$status" == fail ]]; then
      log_error "${check} failed for ${values}"
      failures=$((failures + 1))
    else
      log_info "${check} passed"
    fi
    results+=("$(printf '{"check":"%s","status":"%s"}' "$check" "$status")")
  done

  if [[ "$json" == true ]]; then
    printf '{"ok":%s,"values":"%s","rendered":"%s","failures":%d,"checks":[%s]}\n' \
      "$([[ $failures -eq 0 ]] && echo true || echo false)" \
      "$(json_escape "$values")" "$(json_escape "$out")" "$failures" \
      "$(
        IFS=,
        echo "${results[*]}"
      )"
  fi

  ((failures == 0)) || exit "$EX_VERIFY"
  log_info "all manifest checks passed for ${values}"
}

main "$@"
