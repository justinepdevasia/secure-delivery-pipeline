#!/usr/bin/env bash
#
# audit-action-pins.sh — enforce this repository's central supply chain rule:
# every third-party action is pinned to a full 40-character commit SHA.
#
# A tag is a mutable pointer. `uses: some/action@v4` means "whatever the
# maintainer — or whoever compromises their account — decides v4 means today".
#
# Two modes:
#   --check  offline. Fails if any `uses:` is not pinned to a 40-char SHA.
#   --drift  online. Also resolves each trailing `# vX.Y.Z` comment through the
#            GitHub API and reports pins that have fallen behind their tag.
#
# Exit codes: 0 all pinned | 1 a required tool is missing | 2 usage error
#             4 an unpinned action was found

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

readonly DEFAULT_ROOT=".github"

usage() {
  cat <<'EOF'
Usage: audit-action-pins.sh [--check | --drift] [--root DIR] [--json] [--help]

Parses every `uses:` in the workflow and composite-action YAML under --root and
asserts it is pinned to a full 40-character commit SHA. Local `./...` references
are exempt: they are versioned by this repository's own history.

Options:
  --check       Offline pinning check. Default.
  --drift       Also resolve each `# vX.Y.Z` comment via the GitHub API and
                report pins that no longer match their tag. Needs gh.
  --root DIR    Directory to scan. Default .github
  --json        Emit a JSON report on stdout.
  -h, --help    Show this help and exit 0.

Exit codes:
  0  every action is pinned (and, with --drift, current)
  1  a required tool is missing
  2  usage error
  4  an unpinned action was found

Examples:
  audit-action-pins.sh --check
  audit-action-pins.sh --drift --json
EOF
}

# collect_uses ROOT — emit "file<TAB>ref<TAB>comment" for every `uses:` found.
collect_uses() {
  local root="$1"
  local file line ref comment
  while IFS= read -r file; do
    while IFS= read -r line; do
      # Strip everything up to and including `uses:`.
      ref="${line#*uses:}"
      ref="${ref#"${ref%%[![:space:]]*}"}"
      comment=""
      if [[ "$ref" == *"#"* ]]; then
        comment="${ref#*#}"
        comment="${comment#"${comment%%[![:space:]]*}"}"
        ref="${ref%%#*}"
      fi
      # Trim trailing whitespace and surrounding quotes.
      ref="${ref%"${ref##*[![:space:]]}"}"
      ref="${ref%\"}"
      ref="${ref#\"}"
      ref="${ref%\'}"
      ref="${ref#\'}"
      [[ -n "$ref" ]] || continue
      printf '%s\t%s\t%s\n' "$file" "$ref" "$comment"
    done < <(grep -hnE '^[[:space:]]*(-[[:space:]]+)?uses:' "$file" | sed 's/^[0-9]*://')
  done < <(find "$root" -type f \( -name '*.yml' -o -name '*.yaml' \) | sort)
}

# resolve_tag OWNER/REPO TAG — current SHA for TAG, or empty on failure.
resolve_tag() {
  gh api "repos/$1/commits/$2" --jq .sha 2>/dev/null || true
}

main() {
  local root="$DEFAULT_ROOT" json=false drift=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --check)
        drift=false
        shift
        ;;
      --drift)
        drift=true
        shift
        ;;
      --root)
        [[ $# -ge 2 ]] || die "--root requires an argument" "$EX_USAGE"
        root="$2"
        shift 2
        ;;
      --root=*)
        root="${1#*=}"
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

  [[ -d "$root" ]] || die "not a directory: ${root}" "$EX_USAGE"
  require_cmd grep find sed
  [[ "$drift" == false ]] || require_cmd gh

  local -a results=()
  local unpinned=0 drifted=0 total=0
  local file ref comment action version status current

  while IFS=$'\t' read -r file ref comment; do
    total=$((total + 1))
    action="${ref%%@*}"
    version="${ref#*@}"
    status=ok
    current=""

    if [[ "$ref" == ./* ]]; then
      status=local
    elif [[ ! "$version" =~ ^[0-9a-f]{40}$ ]]; then
      log_error "unpinned: ${file}: ${ref}"
      status=unpinned
      unpinned=$((unpinned + 1))
    elif [[ "$drift" == true && "$comment" =~ ^v?[0-9]+(\.[0-9]+)*$ ]]; then
      current="$(resolve_tag "$action" "$comment")"
      if [[ -n "$current" && "$current" != "$version" ]]; then
        log_warn "drift: ${file}: ${action}@${comment} is now ${current}, pinned to ${version}"
        status=drift
        drifted=$((drifted + 1))
      fi
    fi

    results+=("$(printf '{"file":"%s","action":"%s","pin":"%s","comment":"%s","current":"%s","status":"%s"}' \
      "$(json_escape "$file")" "$(json_escape "$action")" "$(json_escape "$version")" \
      "$(json_escape "$comment")" "$(json_escape "$current")" "$status")")
  done < <(collect_uses "$root")

  if [[ "$json" == true ]]; then
    printf '{"ok":%s,"scanned":%d,"unpinned":%d,"drifted":%d,"actions":[%s]}\n' \
      "$([[ $unpinned -eq 0 ]] && echo true || echo false)" \
      "$total" "$unpinned" "$drifted" \
      "$(
        IFS=,
        echo "${results[*]}"
      )"
  fi

  if ((unpinned > 0)); then
    log_error "${unpinned} of ${total} action reference(s) are not pinned to a commit SHA"
    exit "$EX_VERIFY"
  fi
  log_info "${total} action reference(s) scanned, all pinned${drifted:+, ${drifted} behind their tag}"
}

main "$@"
