#!/usr/bin/env bats
# Unit tests for scripts/audit-action-pins.sh — fixture workflow trees in
# BATS_TEST_TMPDIR, gh stubbed for the drift path.

load helper

SHA_A="11bd71901bbe5b1630ceea73d27597364c9af683"
SHA_B="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

setup() {
  setup_common
  AUDIT="${SCRIPTS}/audit-action-pins.sh"
  ROOT="${BATS_TEST_TMPDIR}/.github/workflows"
  mkdir -p "$ROOT"
  export AUDIT ROOT SHA_A SHA_B
}

workflow() {
  cat >"${ROOT}/$1"
}

@test "--help exits 0 and documents exit code 4" {
  run "$AUDIT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"4  an unpinned action was found"* ]]
}

@test "an unknown flag is a usage error" {
  run "$AUDIT" --nonsense
  [ "$status" -eq 2 ]
}

@test "a missing root directory is a usage error" {
  run "$AUDIT" --root "${BATS_TEST_TMPDIR}/absent"
  [ "$status" -eq 2 ]
}

@test "a fully pinned workflow passes" {
  workflow ok.yml <<EOF
jobs:
  a:
    steps:
      - uses: actions/checkout@${SHA_A} # v4.2.2
EOF
  run "$AUDIT" --check --root "${BATS_TEST_TMPDIR}/.github"
  [ "$status" -eq 0 ]
}

@test "a floating tag is flagged and exits 4" {
  workflow bad.yml <<'EOF'
jobs:
  a:
    steps:
      - uses: actions/checkout@v4
EOF
  run "$AUDIT" --check --root "${BATS_TEST_TMPDIR}/.github"
  [ "$status" -eq 4 ]
  [[ "$output" == *"unpinned"* ]]
  [[ "$output" == *"actions/checkout@v4"* ]]
}

@test "a branch name is flagged" {
  workflow branch.yml <<'EOF'
jobs:
  a:
    steps:
      - uses: some/action@main
EOF
  run "$AUDIT" --check --root "${BATS_TEST_TMPDIR}/.github"
  [ "$status" -eq 4 ]
}

@test "a short SHA is flagged — 40 characters or nothing" {
  workflow short.yml <<'EOF'
jobs:
  a:
    steps:
      - uses: some/action@11bd719
EOF
  run "$AUDIT" --check --root "${BATS_TEST_TMPDIR}/.github"
  [ "$status" -eq 4 ]
}

@test "local ./.github/actions references are exempt" {
  workflow local.yml <<'EOF'
jobs:
  a:
    steps:
      - uses: ./.github/actions/setup-floci
EOF
  run "$AUDIT" --check --root "${BATS_TEST_TMPDIR}/.github"
  [ "$status" -eq 0 ]
}

@test "reusable workflow calls are checked too" {
  workflow reusable.yml <<'EOF'
jobs:
  a:
    uses: other/repo/.github/workflows/x.yml@v1
EOF
  run "$AUDIT" --check --root "${BATS_TEST_TMPDIR}/.github"
  [ "$status" -eq 4 ]
}

@test "--json reports every reference with its status" {
  workflow mixed.yml <<EOF
jobs:
  a:
    steps:
      - uses: actions/checkout@${SHA_A} # v4.2.2
      - uses: bad/action@v1
      - uses: ./.github/actions/local
EOF
  run --separate-stderr "$AUDIT" --check --root "${BATS_TEST_TMPDIR}/.github" --json
  [ "$status" -eq 4 ]
  echo "$output" | jq -e '.ok == false and .scanned == 3 and .unpinned == 1'
  echo "$output" | jq -e '[.actions[] | select(.status == "local")] | length == 1'
  echo "$output" | jq -e '[.actions[] | select(.status == "ok")] | length == 1'
}

@test "--drift reports a pin that has fallen behind its tag" {
  workflow drift.yml <<EOF
jobs:
  a:
    steps:
      - uses: actions/checkout@${SHA_A} # v4.2.2
EOF
  stub gh "echo '${SHA_B}'"
  run --separate-stderr "$AUDIT" --drift --root "${BATS_TEST_TMPDIR}/.github" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.drifted == 1'
  echo "$output" | jq -e '.actions[0].status == "drift"'
}

@test "--drift stays quiet when the pin matches the tag" {
  workflow current.yml <<EOF
jobs:
  a:
    steps:
      - uses: actions/checkout@${SHA_A} # v4.2.2
EOF
  stub gh "echo '${SHA_A}'"
  run --separate-stderr "$AUDIT" --drift --root "${BATS_TEST_TMPDIR}/.github" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.drifted == 0 and .actions[0].status == "ok"'
}

@test "this repository passes its own pinning rule" {
  run "$AUDIT" --check --root "${REPO_ROOT}/.github"
  [ "$status" -eq 0 ]
}
