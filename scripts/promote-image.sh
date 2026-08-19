#!/usr/bin/env bash
#
# promote-image.sh — copy an image between registries by digest, and refuse to do
# it if the source digest is not signed.
#
# Promotion by tag is how a reviewed image and a deployed image drift apart: the
# tag can be moved between the two operations. This only ever moves a digest, and
# checks the signature first, so an unsigned or tampered image cannot be promoted
# into the registry a cluster pulls from.
#
# Exit codes: 0 promoted | 1 a required tool is missing | 2 usage error
#             4 the source digest failed verification

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
  cat <<'EOF'
Usage: promote-image.sh --source IMAGE --digest sha256:... --target IMAGE --repo OWNER/NAME [options]

Pulls the source image by digest, verifies its supply chain, retags it and pushes
it to the target registry. Never resolves a tag on either side.

Options:
  --source IMAGE     Source repository without a tag. Required.
  --digest DIGEST    sha256:... digest to promote. Required.
  --target IMAGE     Target repository without a tag. Required.
  --repo OWNER/NAME  Repository expected to have produced the image. Required.
  --tag TAG          Tag to apply at the target, in addition to the digest.
                     Default: the digest's hex, so the tag is still immutable.
  --skip-verify      Promote without checking the signature. Refuses unless
                     PROMOTE_ALLOW_UNSIGNED=1 is also set.
  --dry-run          Print what would happen, change nothing.
  --json             Emit a JSON report on stdout.
  -h, --help         Show this help and exit 0.

Exit codes:
  0  the image was promoted
  1  a required tool is missing
  2  usage error
  4  the source digest failed supply chain verification

Example:
  promote-image.sh --source ghcr.io/acme/app/api --digest sha256:abc... \
    --target 000000000000.dkr.ecr.us-east-1.amazonaws.com/acme/api --repo acme/app
EOF
}

main() {
  local source="" digest="" target="" repo="" tag=""
  local skip_verify=false dry_run=false json=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --source)
        [[ $# -ge 2 ]] || die "--source requires an argument" "$EX_USAGE"
        source="$2"
        shift 2
        ;;
      --digest)
        [[ $# -ge 2 ]] || die "--digest requires an argument" "$EX_USAGE"
        digest="$2"
        shift 2
        ;;
      --target)
        [[ $# -ge 2 ]] || die "--target requires an argument" "$EX_USAGE"
        target="$2"
        shift 2
        ;;
      --repo)
        [[ $# -ge 2 ]] || die "--repo requires an argument" "$EX_USAGE"
        repo="$2"
        shift 2
        ;;
      --tag)
        [[ $# -ge 2 ]] || die "--tag requires an argument" "$EX_USAGE"
        tag="$2"
        shift 2
        ;;
      --skip-verify)
        skip_verify=true
        shift
        ;;
      --dry-run)
        dry_run=true
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

  [[ -n "$source" ]] || {
    usage >&2
    die "--source is required" "$EX_USAGE"
  }
  [[ -n "$target" ]] || {
    usage >&2
    die "--target is required" "$EX_USAGE"
  }
  [[ -n "$repo" ]] || {
    usage >&2
    die "--repo is required" "$EX_USAGE"
  }
  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] ||
    die "--digest must be a full sha256:... digest, got '${digest}'" "$EX_USAGE"

  if [[ "$skip_verify" == true && "${PROMOTE_ALLOW_UNSIGNED:-0}" != "1" ]]; then
    die "--skip-verify also requires PROMOTE_ALLOW_UNSIGNED=1; promoting an unverified image is not a default" "$EX_USAGE"
  fi

  # Tag derived from the digest by default: still immutable, still traceable.
  [[ -n "$tag" ]] || tag="${digest#sha256:}"

  local source_ref="${source}@${digest}"
  local target_ref="${target}:${tag}"

  if [[ "$skip_verify" == false ]]; then
    log_info "verifying ${source_ref} before promotion"
    if [[ "$dry_run" == true ]]; then
      log_info "dry-run: verify-supply-chain.sh --image ${source} --digest ${digest} --repo ${repo}"
    elif ! "${SCRIPT_DIR}/verify-supply-chain.sh" \
      --image "$source" --digest "$digest" --repo "$repo" >/dev/null; then
      log_error "refusing to promote: ${source_ref} failed supply chain verification"
      if [[ "$json" == true ]]; then
        printf '{"ok":false,"reason":"verification-failed","source":"%s"}\n' \
          "$(json_escape "$source_ref")"
      fi
      exit "$EX_VERIFY"
    fi
  else
    log_warn "promoting without verification — PROMOTE_ALLOW_UNSIGNED is set"
  fi

  local target_digest="$digest"

  if [[ "$dry_run" == true ]]; then
    log_info "dry-run: docker pull ${source_ref}"
    log_info "dry-run: docker tag ${source_ref} ${target_ref}"
    log_info "dry-run: docker push ${target_ref}"
  else
    require_cmd docker
    retry_with_backoff 3 docker pull "$source_ref"
    docker tag "$source_ref" "$target_ref"
    retry_with_backoff 3 docker push "$target_ref"

    # Re-uploading a manifest to a different registry does not have to preserve
    # its digest, so the target digest is read back rather than assumed. Anything
    # downstream must pin the digest that actually exists where it will be pulled
    # from — pinning the source digest would produce an unpullable reference.
    if resolved="$(docker buildx imagetools inspect "$target_ref" \
      --format '{{.Manifest.Digest}}' 2>/dev/null)"; then
      resolved="$(printf '%s' "$resolved" | tr -d '[:space:]')"
      if [[ "$resolved" =~ ^sha256:[0-9a-f]{64}$ ]]; then
        target_digest="$resolved"
      fi
    fi
    [[ "$target_digest" == "$digest" ]] ||
      log_info "target digest differs from source: ${target_digest}"
  fi

  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
      echo "digest=${target_digest}"
      echo "reference=${target}@${target_digest}"
    } >>"$GITHUB_OUTPUT"
  fi

  if [[ "$json" == true ]]; then
    printf '{"ok":true,"source":"%s","target":"%s","digest":"%s","target_digest":"%s","dry_run":%s}\n' \
      "$(json_escape "$source_ref")" "$(json_escape "$target_ref")" \
      "$(json_escape "$digest")" "$(json_escape "$target_digest")" "$dry_run"
  fi
  log_info "promoted ${source_ref} to ${target}@${target_digest}"
}

main "$@"
