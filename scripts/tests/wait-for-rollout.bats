#!/usr/bin/env bats
# Unit tests for scripts/wait-for-rollout.sh — kubectl is stubbed.

load helper

setup() {
  setup_common
  WAIT="${SCRIPTS}/wait-for-rollout.sh"
  OUT="${BATS_TEST_TMPDIR}/diagnostics"
  export WAIT OUT
}

@test "--help exits 0 and documents exit code 3" {
  run "$WAIT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"3  the rollout did not complete within --timeout"* ]]
}

@test "a missing --deployment is a usage error" {
  run "$WAIT" --namespace default
  [ "$status" -eq 2 ]
}

@test "a non-numeric --timeout is a usage error" {
  run "$WAIT" --deployment api --timeout soon
  [ "$status" -eq 2 ]
}

@test "an unknown flag is a usage error" {
  run "$WAIT" --deployment api --bogus
  [ "$status" -eq 2 ]
}

@test "returns 0 when the rollout completes" {
  stub kubectl "exit 0"
  run "$WAIT" --deployment api --timeout 5 --no-diagnostics
  [ "$status" -eq 0 ]
  [[ "$output" == *"rolled out"* ]]
}

@test "exits 3 when the rollout does not complete" {
  stub kubectl "exit 1"
  run "$WAIT" --deployment api --timeout 5 --no-diagnostics
  [ "$status" -eq 3 ]
  [[ "$output" == *"did not roll out"* ]]
}

@test "collects diagnostics before exiting on failure" {
  stub kubectl "exit 1"
  stub helm "exit 0"
  run "$WAIT" --deployment api --timeout 5 --diagnostics "$OUT"
  [ "$status" -eq 3 ]
  [ -f "${OUT}.tar.gz" ]
}

@test "--no-diagnostics skips collection" {
  stub kubectl "exit 1"
  run "$WAIT" --deployment api --timeout 5 --diagnostics "$OUT" --no-diagnostics
  [ "$status" -eq 3 ]
  [ ! -e "${OUT}.tar.gz" ]
}

@test "--json reports the outcome" {
  stub kubectl "exit 0"
  run --separate-stderr "$WAIT" --deployment api --timeout 5 --json --no-diagnostics
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.ok == true and .deployment == "api"'
}

@test "--json still reports on timeout" {
  stub kubectl "exit 1"
  run --separate-stderr "$WAIT" --deployment api --timeout 5 --json --no-diagnostics
  [ "$status" -eq 3 ]
  echo "$output" | jq -e '.ok == false'
}
