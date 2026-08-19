#!/usr/bin/env bash
#
# preflight.sh — assert the CLIs a job needs exist and meet a minimum version.
#
# Run this as the first step of any job with external tool dependencies: a clear
# "helm 3.9.0 is older than the required 3.14.0" beats a cryptic failure twenty
# minutes into a deploy.
#
# Exit codes: 0 all tools satisfied | 1 a tool is missing or too old
#             2 usage error

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

readonly DEFAULT_TOOLS=("bash:4.0" "curl" "jq:1.6")

usage() {
  cat <<'EOF'
Usage: preflight.sh [--tool NAME[:MIN_VERSION]]... [--json] [--help]

Asserts that each named CLI is on PATH and, when a minimum version is given,
that it is at least that version.

Options:
  --tool NAME[:MIN_VERSION]  Tool to check. Repeatable. Defaults to bash, curl, jq.
  --json                     Emit a JSON report on stdout instead of a table.
  -h, --help                 Show this help and exit 0.

Exit codes:
  0  every tool satisfied
  1  a tool is missing or below its minimum version
  2  usage error

Examples:
  preflight.sh --tool docker --tool helm:3.14.0 --tool kubectl
  preflight.sh --json
EOF
}

# tool_version CMD — best-effort version extraction; prints the first dotted number.
tool_version() {
  local cmd="$1"
  local raw
  raw="$("$cmd" --version 2>&1 | head -n 3 || true)"
  printf '%s' "$raw" | grep -Eo '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n 1
}

# version_at_least HAVE WANT
version_at_least() {
  local have="$1" want="$2"
  [[ "$(printf '%s\n%s\n' "$want" "$have" | sort -V | head -n 1)" == "$want" ]]
}

main() {
  local -a tools=()
  local json=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --tool)
        [[ $# -ge 2 ]] || die "--tool requires an argument" "$EX_USAGE"
        tools+=("$2")
        shift 2
        ;;
      --tool=*)
        tools+=("${1#*=}")
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

  if ((${#tools[@]} == 0)); then
    tools=("${DEFAULT_TOOLS[@]}")
  fi

  local -a results=()
  local failures=0
  local spec cmd want have status

  for spec in "${tools[@]}"; do
    cmd="${spec%%:*}"
    want=""
    [[ "$spec" == *:* ]] && want="${spec#*:}"

    if ! command -v "$cmd" >/dev/null 2>&1; then
      log_error "missing: ${cmd}"
      status="missing"
      have=""
      failures=$((failures + 1))
    else
      have="$(tool_version "$cmd")"
      if [[ -n "$want" && -n "$have" ]] && ! version_at_least "$have" "$want"; then
        log_error "${cmd} ${have} is older than the required ${want}"
        status="outdated"
        failures=$((failures + 1))
      else
        log_info "ok: ${cmd} ${have:-unknown}"
        status="ok"
      fi
    fi

    results+=("$(printf '{"tool":"%s","required":"%s","found":"%s","status":"%s"}' \
      "$(json_escape "$cmd")" "$(json_escape "$want")" "$(json_escape "$have")" "$status")")
  done

  if [[ "$json" == true ]]; then
    printf '{"ok":%s,"failures":%d,"tools":[%s]}\n' \
      "$([[ $failures -eq 0 ]] && echo true || echo false)" \
      "$failures" \
      "$(
        IFS=,
        echo "${results[*]}"
      )"
  else
    printf '%-16s %-10s %-10s %s\n' TOOL REQUIRED FOUND STATUS
    for spec in "${tools[@]}"; do
      cmd="${spec%%:*}"
      want=""
      [[ "$spec" == *:* ]] && want="${spec#*:}"
      have="$(command -v "$cmd" >/dev/null 2>&1 && tool_version "$cmd" || echo '-')"
      printf '%-16s %-10s %-10s %s\n' "$cmd" "${want:--}" "${have:--}" \
        "$(command -v "$cmd" >/dev/null 2>&1 && echo present || echo MISSING)"
    done
  fi

  ((failures == 0)) || exit "$EX_FAIL"
}

main "$@"
