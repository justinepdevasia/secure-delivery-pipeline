#!/usr/bin/env bats
# Unit tests for scripts/preflight.sh — external tools are stubbed onto PATH.

load helper

setup() {
  setup_common
  PREFLIGHT="${SCRIPTS}/preflight.sh"
}

@test "--help exits 0 and documents the exit codes" {
  run "$PREFLIGHT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Exit codes:"* ]]
  [[ "$output" == *"2  usage error"* ]]
}

@test "an unknown flag is a usage error" {
  run "$PREFLIGHT" --nope
  [ "$status" -eq 2 ]
}

@test "--tool without a value is a usage error" {
  run "$PREFLIGHT" --tool
  [ "$status" -eq 2 ]
}

@test "a missing tool fails with exit 1 and names the tool" {
  run "$PREFLIGHT" --tool definitely-not-installed
  [ "$status" -eq 1 ]
  [[ "$output" == *"definitely-not-installed"* ]]
}

@test "a present tool at a sufficient version passes" {
  stub faketool 'echo "faketool version 3.14.0"'
  run "$PREFLIGHT" --tool faketool:3.0.0
  [ "$status" -eq 0 ]
}

@test "a present tool below the minimum version fails with exit 1" {
  stub faketool 'echo "faketool version 1.2.3"'
  run "$PREFLIGHT" --tool faketool:2.0.0
  [ "$status" -eq 1 ]
  [[ "$output" == *"older than the required 2.0.0"* ]]
}

@test "version comparison is numeric, not lexicographic" {
  stub faketool 'echo "faketool version 3.10.0"'
  run "$PREFLIGHT" --tool faketool:3.9.0
  [ "$status" -eq 0 ]
}

@test "--json emits parseable JSON on stdout with logs on stderr" {
  stub faketool 'echo "faketool version 2.0.0"'
  run --separate-stderr "$PREFLIGHT" --tool faketool:1.0.0 --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.ok == true and .failures == 0 and (.tools | length) == 1'
  echo "$output" | jq -e '.tools[0].tool == "faketool" and .tools[0].status == "ok"'
  [[ "$stderr" == *"[INFO]"* ]]
}

@test "--json reports failures without exiting 0" {
  run --separate-stderr "$PREFLIGHT" --tool definitely-not-installed --json
  [ "$status" -eq 1 ]
  echo "$output" | jq -e '.ok == false and .failures == 1'
}

@test "--tool=value form is accepted" {
  stub faketool 'echo "faketool version 9.9.9"'
  run "$PREFLIGHT" --tool=faketool:1.0.0
  [ "$status" -eq 0 ]
}
