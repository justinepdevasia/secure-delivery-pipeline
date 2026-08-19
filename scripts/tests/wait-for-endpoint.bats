#!/usr/bin/env bats
# Unit tests for scripts/wait-for-endpoint.sh — curl is stubbed onto PATH, so
# these run offline and finish in milliseconds.

load helper

setup() {
  setup_common
  WAIT="${SCRIPTS}/wait-for-endpoint.sh"
  CALLS="$(stub_calls curl)"
  export CALLS
}

# A curl stub that prints $1 as the HTTP status and records each invocation.
stub_curl_status() {
  stub curl "echo \"call\" >>'${CALLS}'" "printf '%s' '$1'"
}

@test "--help exits 0 and documents exit code 3" {
  run "$WAIT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"3  timed out"* ]]
}

@test "missing --url is a usage error" {
  run "$WAIT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"--url is required"* ]]
}

@test "unknown flag is a usage error" {
  run "$WAIT" --url http://example.invalid --bogus
  [ "$status" -eq 2 ]
}

@test "a non-numeric --timeout is a usage error" {
  run "$WAIT" --url http://example.invalid --timeout soon
  [ "$status" -eq 2 ]
}

@test "returns 0 as soon as the endpoint answers with the expected status" {
  stub_curl_status 200
  run "$WAIT" --url http://example.invalid --timeout 5
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$CALLS")" -eq 1 ]
}

@test "honours a custom --expect-status" {
  stub_curl_status 204
  run "$WAIT" --url http://example.invalid --expect-status 204 --timeout 5
  [ "$status" -eq 0 ]
}

@test "exits 3 when the endpoint never becomes healthy" {
  stub_curl_status 503
  run "$WAIT" --url http://example.invalid --timeout 1 --interval 1
  [ "$status" -eq 3 ]
  [[ "$output" == *"timed out"* ]]
}

@test "exits 3 when curl itself cannot connect" {
  stub curl "exit 7"
  run "$WAIT" --url http://example.invalid --timeout 1 --interval 1
  [ "$status" -eq 3 ]
  [[ "$output" == *"last status 000"* ]]
}

@test "retries until the endpoint recovers" {
  stub curl \
    "echo call >>'${CALLS}'" \
    "if [ \"\$(wc -l <'${CALLS}')\" -ge 3 ]; then printf 200; else printf 503; fi"
  run "$WAIT" --url http://example.invalid --timeout 30 --interval 0
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$CALLS")" -eq 3 ]
}

@test "--json emits a machine-readable result on stdout" {
  stub_curl_status 200
  run --separate-stderr "$WAIT" --url http://example.invalid --json --timeout 5
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.ok == true and .status == "200" and .attempts >= 1'
}

@test "--json still reports on timeout" {
  stub_curl_status 500
  run --separate-stderr "$WAIT" --url http://example.invalid --json --timeout 1 --interval 1
  [ "$status" -eq 3 ]
  echo "$output" | jq -e '.ok == false and .status == "500"'
}
