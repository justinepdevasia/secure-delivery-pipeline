#!/usr/bin/env bats
# Unit tests for scripts/collect-diagnostics.sh — kubectl, helm and docker are
# stubbed. The point of these tests is that a collector never aborts the bundle.

load helper

setup() {
  setup_common
  COLLECT="${SCRIPTS}/collect-diagnostics.sh"
  OUT="${BATS_TEST_TMPDIR}/diag"
  export COLLECT OUT
}

@test "--help exits 0" {
  run "$COLLECT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Exit codes:"* ]]
}

@test "an unknown flag is a usage error" {
  run "$COLLECT" --bogus
  [ "$status" -eq 2 ]
}

@test "writes a tarball" {
  stub kubectl "exit 0"
  run "$COLLECT" --out "$OUT"
  [ "$status" -eq 0 ]
  [ -f "${OUT}.tar.gz" ]
}

@test "--no-archive leaves the directory" {
  stub kubectl "exit 0"
  run "$COLLECT" --out "$OUT" --no-archive
  [ "$status" -eq 0 ]
  [ -d "$OUT" ]
  [ ! -e "${OUT}.tar.gz" ]
}

@test "a failing collector does not abort the bundle" {
  # Every kubectl call fails; the bundle must still be produced, and must record
  # the failure rather than silently omitting the file.
  stub kubectl "echo 'the server could not find the requested resource' >&2" "exit 1"
  run "$COLLECT" --out "$OUT" --no-archive
  [ "$status" -eq 0 ]
  [ -f "${OUT}/events.txt" ]
  grep -q "collector exited 1" "${OUT}/events.txt"
}

@test "collects per-pod describe and logs, including the previous container" {
  stub kubectl \
    'case "$1" in
      get) if [ "$2" = "pods" ]; then echo "pod/api-abc123"; fi ;;
      *) echo "stub output" ;;
    esac' \
    "exit 0"
  run "$COLLECT" --out "$OUT" --no-archive
  [ "$status" -eq 0 ]
  [ -f "${OUT}/pods/api-abc123.describe.txt" ]
  [ -f "${OUT}/pods/api-abc123.log" ]
  [ -f "${OUT}/pods/api-abc123.previous.log" ]
}

@test "includes the emulator log when docker is available" {
  stub kubectl "exit 0"
  stub docker "echo 'floci log line'"
  run "$COLLECT" --out "$OUT" --no-archive
  [ "$status" -eq 0 ]
  grep -q "floci log line" "${OUT}/floci.log"
}

@test "includes helm release history when helm is available" {
  stub kubectl "exit 0"
  stub helm "echo 'REVISION UPDATED STATUS'"
  run "$COLLECT" --out "$OUT" --no-archive
  [ "$status" -eq 0 ]
  grep -q "REVISION" "${OUT}/helm-history.txt"
}
