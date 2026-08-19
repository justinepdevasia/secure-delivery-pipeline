#!/usr/bin/env bats
# Unit tests for scripts/promote-image.sh — docker and the verifier are stubbed,
# so nothing here touches a registry.

load helper

DIGEST="sha256:1111111111111111111111111111111111111111111111111111111111111111"

setup() {
  setup_common
  PROMOTE="${SCRIPTS}/promote-image.sh"
  SOURCE="ghcr.io/acme/app/api"
  TARGET="000000000000.dkr.ecr.us-east-1.amazonaws.com/acme/api"
  REPO="acme/app"
  CALLS="${BATS_TEST_TMPDIR}/docker.calls"
  export PROMOTE SOURCE TARGET REPO CALLS DIGEST
}

stub_docker() {
  stub docker "echo \"docker \$*\" >>'${CALLS}'" "exit ${1:-0}"
}

# The verifier lives next to the script under test, so it is stubbed by shadowing
# SCRIPT_DIR's copy through a temporary scripts directory on PATH is not possible;
# instead the real verifier is exercised with stubbed cosign/gh.
stub_verifier_pass() {
  stub cosign "exit 0"
  stub gh "exit 0"
}

stub_verifier_fail() {
  stub cosign "exit 1"
  stub gh "exit 0"
}

@test "--help exits 0 and documents exit code 4" {
  run "$PROMOTE" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"4  the source digest failed supply chain verification"* ]]
}

@test "a missing --source is a usage error" {
  run "$PROMOTE" --target "$TARGET" --repo "$REPO" --digest "$DIGEST"
  [ "$status" -eq 2 ]
}

@test "a missing --target is a usage error" {
  run "$PROMOTE" --source "$SOURCE" --repo "$REPO" --digest "$DIGEST"
  [ "$status" -eq 2 ]
}

@test "a tag instead of a digest is a usage error" {
  run "$PROMOTE" --source "$SOURCE" --target "$TARGET" --repo "$REPO" --digest v1.0.0
  [ "$status" -eq 2 ]
  [[ "$output" == *"full sha256"* ]]
}

@test "--skip-verify alone is refused" {
  run "$PROMOTE" --source "$SOURCE" --target "$TARGET" --repo "$REPO" \
    --digest "$DIGEST" --skip-verify
  [ "$status" -eq 2 ]
  [[ "$output" == *"PROMOTE_ALLOW_UNSIGNED"* ]]
}

@test "refuses to promote an unsigned digest, with exit 4" {
  stub_verifier_fail
  stub_docker 0
  run "$PROMOTE" --source "$SOURCE" --target "$TARGET" --repo "$REPO" --digest "$DIGEST"
  [ "$status" -eq 4 ]
  [[ "$output" == *"refusing to promote"* ]]
  [ ! -f "$CALLS" ]
}

@test "promotes a verified digest and pushes by digest-derived tag" {
  stub_verifier_pass
  stub_docker 0
  run "$PROMOTE" --source "$SOURCE" --target "$TARGET" --repo "$REPO" --digest "$DIGEST"
  [ "$status" -eq 0 ]
  grep -q "docker pull ${SOURCE}@${DIGEST}" "$CALLS"
  grep -q "docker push ${TARGET}:${DIGEST#sha256:}" "$CALLS"
}

@test "never references the source by tag" {
  stub_verifier_pass
  stub_docker 0
  run "$PROMOTE" --source "$SOURCE" --target "$TARGET" --repo "$REPO" --digest "$DIGEST"
  [ "$status" -eq 0 ]
  ! grep -qE "docker pull ${SOURCE}:" "$CALLS"
}

@test "--tag overrides the derived tag" {
  stub_verifier_pass
  stub_docker 0
  run "$PROMOTE" --source "$SOURCE" --target "$TARGET" --repo "$REPO" \
    --digest "$DIGEST" --tag deadbeef
  [ "$status" -eq 0 ]
  grep -q "docker push ${TARGET}:deadbeef" "$CALLS"
}

@test "--dry-run mutates nothing" {
  stub_verifier_pass
  stub_docker 0
  run "$PROMOTE" --source "$SOURCE" --target "$TARGET" --repo "$REPO" \
    --digest "$DIGEST" --dry-run
  [ "$status" -eq 0 ]
  [ ! -f "$CALLS" ]
}

@test "--json reports the promoted references" {
  stub_verifier_pass
  stub_docker 0
  run --separate-stderr "$PROMOTE" --source "$SOURCE" --target "$TARGET" --repo "$REPO" \
    --digest "$DIGEST" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e --arg s "${SOURCE}@${DIGEST}" '.ok == true and .source == $s'
}

@test "--skip-verify with the override does not call the verifier" {
  stub cosign "exit 1"
  stub gh "exit 1"
  stub_docker 0
  PROMOTE_ALLOW_UNSIGNED=1 run "$PROMOTE" --source "$SOURCE" --target "$TARGET" \
    --repo "$REPO" --digest "$DIGEST" --skip-verify
  [ "$status" -eq 0 ]
  grep -q "docker push" "$CALLS"
}

@test "reports the digest the image has at the target, not the source digest" {
  # Re-uploading a manifest can change its digest; deploying the source digest
  # would produce a reference that cannot be pulled from the target registry.
  local target_digest="sha256:3333333333333333333333333333333333333333333333333333333333333333"
  stub_verifier_pass
  stub docker \
    "echo \"docker \$*\" >>'${CALLS}'" \
    "if [ \"\$1\" = push ]; then echo 'latest: digest: ${target_digest} size: 1234'; fi" \
    "exit 0"
  GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/out" run --separate-stderr "$PROMOTE" \
    --source "$SOURCE" --target "$TARGET" --repo "$REPO" --digest "$DIGEST" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e --arg t "$target_digest" --arg s "$DIGEST" \
    '.target_digest == $t and .digest == $s'
  grep -q "digest=${target_digest}" "${BATS_TEST_TMPDIR}/out"
}

@test "falls back to the source digest when the push output reveals nothing" {
  stub_verifier_pass
  stub docker \
    "echo \"docker \$*\" >>'${CALLS}'" \
    "if [ \"\$1\" = buildx ]; then exit 1; fi" \
    "exit 0"
  run --separate-stderr "$PROMOTE" --source "$SOURCE" --target "$TARGET" \
    --repo "$REPO" --digest "$DIGEST" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e --arg s "$DIGEST" '.target_digest == $s'
}
