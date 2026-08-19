#!/usr/bin/env bash
#
# assert-emulated-infra.sh — after `terraform apply` against the emulator, check
# that the resources actually exist by asking the AWS API for them.
#
# `terraform apply` reporting success only means Terraform believes it succeeded.
# These are independent reads through the AWS CLI, which is a different code path.
#
# Exit codes: 0 every resource present | 1 a required tool is missing
#             2 usage error | 4 a resource is missing

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

readonly DEFAULT_PREFIX="secure-delivery-pipeline-emulated"
readonly DEFAULT_PROJECT="secure-delivery-pipeline"

usage() {
  cat <<'EOF'
Usage: assert-emulated-infra.sh [--prefix NAME] [--project NAME] [--json] [--help]

Reads back, through the AWS CLI, the resources the emulated apply should have
created: the CI role, the cluster role, the ECR repositories, the EKS cluster,
the Secrets Manager secret and the Karpenter interruption queue.

Options:
  --prefix NAME    Resource name prefix. Default secure-delivery-pipeline-emulated
  --project NAME   Project prefix for ECR and secret names. Default secure-delivery-pipeline
  --json           Emit a JSON report on stdout.
  -h, --help       Show this help and exit 0.

Exit codes:
  0  every asserted resource exists
  1  a required tool is missing
  2  usage error
  4  a resource is missing
EOF
}

main() {
  local prefix="$DEFAULT_PREFIX" project="$DEFAULT_PROJECT" json=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --prefix)
        [[ $# -ge 2 ]] || die "--prefix requires an argument" "$EX_USAGE"
        prefix="$2"
        shift 2
        ;;
      --project)
        [[ $# -ge 2 ]] || die "--project requires an argument" "$EX_USAGE"
        project="$2"
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

  require_cmd aws

  # name<TAB>command
  local -a checks=(
    "iam-role-github-actions	aws iam get-role --role-name ${prefix}-github-actions"
    "iam-role-cluster	aws iam get-role --role-name ${prefix}-cluster"
    "iam-role-node	aws iam get-role --role-name ${prefix}-node"
    "iam-role-karpenter	aws iam get-role --role-name ${prefix}-karpenter"
    "ecr-api-python	aws ecr describe-repositories --repository-names ${project}/api-python"
    "ecr-api-dotnet	aws ecr describe-repositories --repository-names ${project}/api-dotnet"
    "eks-cluster	aws eks describe-cluster --name ${prefix}"
    "secret	aws secretsmanager describe-secret --secret-id ${project}/api-python"
    "sqs-karpenter	aws sqs get-queue-url --queue-name ${prefix}-karpenter-interruption"
  )

  local -a results=()
  local failures=0 entry name cmd status

  for entry in "${checks[@]}"; do
    name="${entry%%$'\t'*}"
    cmd="${entry#*$'\t'}"
    status=present
    # shellcheck disable=SC2086  # cmd is a fixed, locally constructed command line
    if ! output="$($cmd 2>&1)"; then
      log_error "missing: ${name} — $(printf '%s' "$output" | tail -n 1 | cut -c1-140)"
      status=missing
      failures=$((failures + 1))
    else
      log_info "present: ${name}"
    fi
    results+=("$(printf '{"resource":"%s","status":"%s"}' "$name" "$status")")
  done

  if [[ "$json" == true ]]; then
    printf '{"ok":%s,"checked":%d,"missing":%d,"resources":[%s]}\n' \
      "$([[ $failures -eq 0 ]] && echo true || echo false)" \
      "${#checks[@]}" "$failures" \
      "$(
        IFS=,
        echo "${results[*]}"
      )"
  fi

  if ((failures > 0)); then
    log_error "${failures} resource(s) missing after apply"
    exit "$EX_VERIFY"
  fi
  log_info "all ${#checks[@]} resources present"
}

main "$@"
