#!/usr/bin/env bash
#
# resolve-image-digest.sh — turn a tag into the digest it currently points at,
# once, at the start of a deploy.
#
# Everything downstream — verification, promotion, the Helm release — uses the
# digest. Resolving it in one place means a tag that moves mid-deploy cannot
# result in verifying one image and shipping another.
#
# Retries, because the deploy can start while the build that pushes the tag is
# still finishing.
#
# Exit codes: 0 resolved | 1 a required tool is missing | 2 usage error
#             3 the tag never appeared

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
  cat <<'EOF'
Usage: resolve-image-digest.sh --image IMAGE [options]

Resolves IMAGE:TAG to its immutable digest and writes `digest=sha256:...` to
$GITHUB_OUTPUT when running under Actions.

Options:
  --image IMAGE     Repository without a tag. Required.
  --tag TAG         Tag to resolve. Default $GITHUB_SHA
  --digest DIGEST   Skip resolution and use this digest, after validating it.
                    An empty value is ignored, so a workflow can pass an
                    optional input straight through.
  --attempts N      Resolution attempts, with exponential backoff. Default 6
  --json            Emit a JSON report on stdout.
  -h, --help        Show this help and exit 0.

Exit codes:
  0  a digest was resolved
  1  a required tool is missing
  2  usage error
  3  the tag did not appear within the retry budget
EOF
}

main() {
  local image="" tag="${GITHUB_SHA:-}" digest="${REQUESTED:-}" attempts=6 json=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --image)
        [[ $# -ge 2 ]] || die "--image requires an argument" "$EX_USAGE"
        image="$2"
        shift 2
        ;;
      --tag)
        [[ $# -ge 2 ]] || die "--tag requires an argument" "$EX_USAGE"
        tag="$2"
        shift 2
        ;;
      --digest)
        [[ $# -ge 2 ]] || die "--digest requires an argument" "$EX_USAGE"
        digest="$2"
        shift 2
        ;;
      --attempts)
        [[ $# -ge 2 ]] || die "--attempts requires an argument" "$EX_USAGE"
        attempts="$2"
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

  [[ -n "$image" ]] || {
    usage >&2
    die "--image is required" "$EX_USAGE"
  }

  local source="resolved"
  if [[ -n "$digest" ]]; then
    [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] ||
      die "--digest must be a full sha256:... digest, got '${digest}'" "$EX_USAGE"
    source="supplied"
    log_info "using the supplied digest ${digest}"
  else
    [[ -n "$tag" ]] || die "--tag is required when no digest is supplied" "$EX_USAGE"
    require_cmd docker

    local scratch
    scratch="$(make_scratch_dir)"
    # shellcheck disable=SC2064  # scratch is expanded now on purpose
    trap "rm -rf '${scratch}'" EXIT

    log_info "resolving ${image}:${tag}"
    if ! RETRY_BASE_DELAY="${RETRY_BASE_DELAY:-10}" retry_with_backoff "$attempts" \
      bash -c "docker buildx imagetools inspect '${image}:${tag}' \
        --format '{{.Manifest.Digest}}' > '${scratch}/digest'"; then
      log_error "${image}:${tag} did not appear within the retry budget"
      exit "$EX_TIMEOUT"
    fi

    digest="$(tr -d '[:space:]' <"${scratch}/digest")"
    [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] ||
      die "registry returned something that is not a digest: '${digest}'" "$EX_FAIL"
  fi

  log_info "digest: ${digest}"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "digest=${digest}" >>"$GITHUB_OUTPUT"
  fi
  if [[ "$json" == true ]]; then
    printf '{"ok":true,"image":"%s","tag":"%s","digest":"%s","source":"%s"}\n' \
      "$(json_escape "$image")" "$(json_escape "$tag")" "$digest" "$source"
  fi
}

main "$@"
