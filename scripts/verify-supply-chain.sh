#!/usr/bin/env bash
#
# verify-supply-chain.sh — prove an image digest carries a valid Sigstore
# signature and GitHub build provenance before anything is allowed to deploy it.
#
# Plenty of pipelines sign. Far fewer gate on verification, which is the point of
# this script: it fails closed, and the deploy workflow calls it before ECR and
# again before Helm.
#
# Exit codes: 0 verified | 1 a required tool is missing | 2 usage error
#             4 verification failed

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

readonly OIDC_ISSUER="https://token.actions.githubusercontent.com"

usage() {
  cat <<'EOF'
Usage: verify-supply-chain.sh --image IMAGE --digest sha256:... --repo OWNER/NAME [options]

Verifies, against the digest and never against a tag:
  * the keyless cosign signature, constrained to workflows in --repo
  * the GitHub build provenance attestation
  * the SBOM attestation, unless --skip-sbom is given

Options:
  --image IMAGE       Registry reference without a tag, e.g. ghcr.io/o/r/api-python
  --digest DIGEST     sha256:... digest to verify. Required.
  --repo OWNER/NAME   Repository expected to have produced the image. Required.
  --skip-sbom         Do not require an SBOM attestation.
  --json              Emit a JSON report on stdout.
  --dry-run           Print the verification commands without running them.
  -h, --help          Show this help and exit 0.

Exit codes:
  0  every requested check passed
  1  a required tool is missing
  2  usage error
  4  a verification check failed

Example:
  verify-supply-chain.sh --image ghcr.io/acme/app/api --digest sha256:abc... \
    --repo acme/app --json
EOF
}

main() {
  local image="" digest="" repo="" json=false dry_run=false skip_sbom=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --image)
        [[ $# -ge 2 ]] || die "--image requires an argument" "$EX_USAGE"
        image="$2"
        shift 2
        ;;
      --image=*)
        image="${1#*=}"
        shift
        ;;
      --digest)
        [[ $# -ge 2 ]] || die "--digest requires an argument" "$EX_USAGE"
        digest="$2"
        shift 2
        ;;
      --digest=*)
        digest="${1#*=}"
        shift
        ;;
      --repo)
        [[ $# -ge 2 ]] || die "--repo requires an argument" "$EX_USAGE"
        repo="$2"
        shift 2
        ;;
      --repo=*)
        repo="${1#*=}"
        shift
        ;;
      --skip-sbom)
        skip_sbom=true
        shift
        ;;
      --json)
        json=true
        shift
        ;;
      --dry-run)
        dry_run=true
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
  [[ -n "$repo" ]] || {
    usage >&2
    die "--repo is required" "$EX_USAGE"
  }
  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] ||
    die "--digest must be a full sha256:... digest, got '${digest}'" "$EX_USAGE"
  [[ "$image" != *:* || "$image" == *:*/* ]] ||
    die "--image must not carry a tag; verification is by digest only" "$EX_USAGE"

  local reference="${image}@${digest}"
  local identity="^https://github.com/${repo}/\\.github/workflows/.+@refs/"

  local -a checks=(signature provenance)
  [[ "$skip_sbom" == true ]] || checks+=(sbom)

  if [[ "$dry_run" == false ]]; then
    require_cmd cosign gh
  fi

  local -a results=()
  local failures=0 check status

  for check in "${checks[@]}"; do
    local -a cmd=()
    case "$check" in
      signature)
        cmd=(cosign verify
          --certificate-identity-regexp "$identity"
          --certificate-oidc-issuer "$OIDC_ISSUER"
          "$reference")
        ;;
      provenance)
        cmd=(gh attestation verify "oci://${reference}"
          --repo "$repo" --predicate-type "https://slsa.dev/provenance/v1")
        ;;
      sbom)
        cmd=(gh attestation verify "oci://${reference}"
          --repo "$repo" --predicate-type "https://cyclonedx.org/bom")
        ;;
    esac

    if [[ "$dry_run" == true ]]; then
      log_info "dry-run: ${cmd[*]}"
      status=skipped
    elif retry_with_backoff 3 "${cmd[@]}" >/dev/null 2>&1; then
      log_info "verified: ${check}"
      status=pass
    else
      log_error "verification failed: ${check} for ${reference}"
      status=fail
      failures=$((failures + 1))
    fi

    results+=("$(printf '{"check":"%s","status":"%s"}' "$check" "$status")")
  done

  if [[ "$json" == true ]]; then
    printf '{"ok":%s,"reference":"%s","repo":"%s","failures":%d,"checks":[%s]}\n' \
      "$([[ $failures -eq 0 ]] && echo true || echo false)" \
      "$(json_escape "$reference")" "$(json_escape "$repo")" "$failures" \
      "$(
        IFS=,
        echo "${results[*]}"
      )"
  fi

  if ((failures > 0)); then
    log_error "${failures} supply chain check(s) failed — refusing to proceed"
    exit "$EX_VERIFY"
  fi
  log_info "supply chain verified for ${reference}"
}

main "$@"
