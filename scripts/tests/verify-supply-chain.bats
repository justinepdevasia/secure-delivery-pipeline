#!/usr/bin/env bats
# Unit tests for scripts/verify-supply-chain.sh — cosign and gh are stubbed, so
# nothing here touches a registry or Sigstore.

load helper

DIGEST="sha256:0000000000000000000000000000000000000000000000000000000000000000"

setup() {
  setup_common
  VERIFY="${SCRIPTS}/verify-supply-chain.sh"
  IMAGE="ghcr.io/acme/app/api-python"
  REPO="acme/app"
  CALLS="${BATS_TEST_TMPDIR}/calls"
  export VERIFY IMAGE REPO CALLS DIGEST
}

stub_all_pass() {
  stub cosign "echo \"cosign \$*\" >>'${CALLS}'" "exit 0"
  stub gh "echo \"gh \$*\" >>'${CALLS}'" "exit 0"
}

@test "--help exits 0 and documents exit code 4" {
  run "$VERIFY" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"4  a verification check failed"* ]]
}

@test "a missing --image is a usage error" {
  run "$VERIFY" --repo "$REPO" --digest "$DIGEST"
  [ "$status" -eq 2 ]
}

@test "a missing --repo is a usage error" {
  run "$VERIFY" --image "$IMAGE" --digest "$DIGEST"
  [ "$status" -eq 2 ]
}

@test "a tag instead of a digest is a usage error" {
  run "$VERIFY" --image "$IMAGE" --repo "$REPO" --digest v1.2.3
  [ "$status" -eq 2 ]
  [[ "$output" == *"full sha256"* ]]
}

@test "a truncated digest is a usage error" {
  run "$VERIFY" --image "$IMAGE" --repo "$REPO" --digest sha256:abc
  [ "$status" -eq 2 ]
}

@test "an unknown flag is a usage error" {
  run "$VERIFY" --image "$IMAGE" --repo "$REPO" --digest "$DIGEST" --nope
  [ "$status" -eq 2 ]
}

@test "verifies signature, provenance and SBOM by digest" {
  stub_all_pass
  run "$VERIFY" --image "$IMAGE" --repo "$REPO" --digest "$DIGEST"
  [ "$status" -eq 0 ]
  grep -q "cosign verify" "$CALLS"
  grep -q "oci://${IMAGE}@${DIGEST}" "$CALLS"
  grep -q "slsa.dev/provenance/v1" "$CALLS"
  grep -q "cyclonedx.org/bom" "$CALLS"
}

@test "the cosign identity regexp is scoped to the given repo" {
  stub_all_pass
  run "$VERIFY" --image "$IMAGE" --repo "$REPO" --digest "$DIGEST"
  [ "$status" -eq 0 ]
  grep -q "github.com/acme/app" "$CALLS"
}

@test "--skip-sbom drops only the SBOM check" {
  stub_all_pass
  run "$VERIFY" --image "$IMAGE" --repo "$REPO" --digest "$DIGEST" --skip-sbom
  [ "$status" -eq 0 ]
  ! grep -q "cyclonedx.org/bom" "$CALLS"
  grep -q "slsa.dev/provenance/v1" "$CALLS"
}

@test "exits 4 when the signature does not verify" {
  stub cosign "exit 1"
  stub gh "exit 0"
  run "$VERIFY" --image "$IMAGE" --repo "$REPO" --digest "$DIGEST"
  [ "$status" -eq 4 ]
  [[ "$output" == *"refusing to proceed"* ]]
}

@test "exits 4 when provenance is missing" {
  stub cosign "exit 0"
  stub gh "exit 1"
  run "$VERIFY" --image "$IMAGE" --repo "$REPO" --digest "$DIGEST"
  [ "$status" -eq 4 ]
}

@test "--json reports every check and stays parseable on failure" {
  stub cosign "exit 1"
  stub gh "exit 0"
  run --separate-stderr "$VERIFY" --image "$IMAGE" --repo "$REPO" --digest "$DIGEST" --json
  [ "$status" -eq 4 ]
  echo "$output" | jq -e '.ok == false and .failures == 1 and (.checks | length) == 3'
  echo "$output" | jq -e '.checks[] | select(.check == "signature") | .status == "fail"'
}

@test "--json reports success with the full reference" {
  stub_all_pass
  run --separate-stderr "$VERIFY" --image "$IMAGE" --repo "$REPO" --digest "$DIGEST" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e --arg r "${IMAGE}@${DIGEST}" '.ok == true and .reference == $r'
}

@test "--dry-run runs no verification commands" {
  : >"$CALLS"
  stub cosign "echo \"cosign \$*\" >>'${CALLS}'" "exit 1"
  stub gh "echo \"gh \$*\" >>'${CALLS}'" "exit 1"
  run "$VERIFY" --image "$IMAGE" --repo "$REPO" --digest "$DIGEST" --dry-run
  [ "$status" -eq 0 ]
  [ ! -s "$CALLS" ]
}

@test "fails with exit 1 when cosign is not installed" {
  stub gh "exit 0"
  run "$VERIFY" --image "$IMAGE" --repo "$REPO" --digest "$DIGEST"
  [ "$status" -eq 1 ]
  [[ "$output" == *"cosign"* ]]
}
