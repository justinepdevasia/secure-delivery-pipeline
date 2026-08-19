#!/usr/bin/env bats
# Unit tests for scripts/lib/common.sh

load helper

setup() {
  setup_common
  # shellcheck source=scripts/lib/common.sh
  source "${SCRIPTS}/lib/common.sh"
}

@test "log helpers write to stderr, never stdout" {
  run --separate-stderr bash -c "source '${SCRIPTS}/lib/common.sh'; log_info hello"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *"[INFO] hello"* ]]
}

@test "log lines carry a UTC timestamp" {
  run --separate-stderr bash -c "source '${SCRIPTS}/lib/common.sh'; log_warn careful"
  [[ "$stderr" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\ \[WARN\]\ careful ]]
}

@test "die exits 1 by default" {
  run bash -c "source '${SCRIPTS}/lib/common.sh'; die 'boom'"
  [ "$status" -eq 1 ]
}

@test "die honours an explicit exit code" {
  run bash -c "source '${SCRIPTS}/lib/common.sh'; die 'bad flag' 2"
  [ "$status" -eq 2 ]
}

@test "require_cmd succeeds when every command is present" {
  run bash -c "source '${SCRIPTS}/lib/common.sh'; require_cmd bash date"
  [ "$status" -eq 0 ]
}

@test "require_cmd names every missing command at once" {
  run bash -c "source '${SCRIPTS}/lib/common.sh'; require_cmd bash definitely-not-here also-missing"
  [ "$status" -eq 1 ]
  [[ "$output" == *"definitely-not-here"* ]]
  [[ "$output" == *"also-missing"* ]]
}

@test "retry_with_backoff returns immediately on first success" {
  run bash -c "RETRY_BASE_DELAY=0; source '${SCRIPTS}/lib/common.sh'; retry_with_backoff 3 true"
  [ "$status" -eq 0 ]
}

@test "retry_with_backoff stops after N attempts and propagates the status" {
  local counter="${BATS_TEST_TMPDIR}/attempts"
  : >"$counter"
  run bash -c "RETRY_BASE_DELAY=0; source '${SCRIPTS}/lib/common.sh'; \
    flaky() { echo x >>'${counter}'; return 7; }; \
    retry_with_backoff 3 flaky"
  [ "$status" -eq 7 ]
  [ "$(wc -l <"$counter")" -eq 3 ]
}

@test "retry_with_backoff succeeds once the command recovers" {
  local counter="${BATS_TEST_TMPDIR}/attempts"
  : >"$counter"
  run bash -c "RETRY_BASE_DELAY=0; source '${SCRIPTS}/lib/common.sh'; \
    flaky() { echo x >>'${counter}'; [ \"\$(wc -l <'${counter}')\" -ge 2 ]; }; \
    retry_with_backoff 5 flaky"
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$counter")" -eq 2 ]
}

@test "json_escape escapes quotes, backslashes and newlines" {
  run bash -c "source '${SCRIPTS}/lib/common.sh'; json_escape 'a\"b\\c'"
  [ "$status" -eq 0 ]
  [ "$output" = 'a\"b\\c' ]
}

@test "sourcing twice is a no-op rather than a readonly error" {
  run bash -c "source '${SCRIPTS}/lib/common.sh'; source '${SCRIPTS}/lib/common.sh'; echo \$EX_TIMEOUT"
  [ "$status" -eq 0 ]
  [ "$output" = "3" ]
}
