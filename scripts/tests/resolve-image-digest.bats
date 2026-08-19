#!/usr/bin/env bats
# Unit tests for scripts/resolve-image-digest.sh — docker is stubbed.

load helper

DIGEST="sha256:2222222222222222222222222222222222222222222222222222222222222222"

setup() {
  setup_common
  RESOLVE="${SCRIPTS}/resolve-image-digest.sh"
  IMAGE="ghcr.io/acme/app/api"
  export RESOLVE IMAGE DIGEST RETRY_BASE_DELAY=0
}

@test "--help exits 0 and documents exit code 3" {
  run "$RESOLVE" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"3  the tag did not appear within the retry budget"* ]]
}

@test "a missing --image is a usage error" {
  run "$RESOLVE" --tag abc123
  [ "$status" -eq 2 ]
}

@test "an unknown flag is a usage error" {
  run "$RESOLVE" --image "$IMAGE" --tag abc --bogus
  [ "$status" -eq 2 ]
}

@test "resolves a tag to its digest" {
  stub docker "echo '${DIGEST}'"
  run --separate-stderr "$RESOLVE" --image "$IMAGE" --tag abc123 --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e --arg d "$DIGEST" '.digest == $d and .source == "resolved"'
}

@test "writes the digest to GITHUB_OUTPUT" {
  stub docker "echo '${DIGEST}'"
  GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/out" run "$RESOLVE" --image "$IMAGE" --tag abc123
  [ "$status" -eq 0 ]
  grep -q "digest=${DIGEST}" "${BATS_TEST_TMPDIR}/out"
}

@test "a supplied digest short-circuits resolution" {
  stub docker "exit 1"
  run --separate-stderr "$RESOLVE" --image "$IMAGE" --digest "$DIGEST" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.source == "supplied"'
}

@test "a supplied tag-shaped digest is a usage error" {
  run "$RESOLVE" --image "$IMAGE" --digest v1.2.3
  [ "$status" -eq 2 ]
}

@test "exits 3 when the tag never appears" {
  stub docker "exit 1"
  run "$RESOLVE" --image "$IMAGE" --tag abc123 --attempts 2
  [ "$status" -eq 3 ]
  [[ "$output" == *"did not appear"* ]]
}

@test "retries until the tag shows up" {
  local counter="${BATS_TEST_TMPDIR}/tries"
  : >"$counter"
  stub docker \
    "echo x >>'${counter}'" \
    "if [ \"\$(wc -l <'${counter}')\" -ge 3 ]; then echo '${DIGEST}'; else exit 1; fi"
  run --separate-stderr "$RESOLVE" --image "$IMAGE" --tag abc123 --attempts 5 --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e --arg d "$DIGEST" '.digest == $d'
}

@test "rejects a registry response that is not a digest" {
  stub docker "echo 'not-a-digest'"
  run "$RESOLVE" --image "$IMAGE" --tag abc123
  [ "$status" -eq 1 ]
  [[ "$output" == *"not a digest"* ]]
}
