#!/usr/bin/env bash
#
# Shared bats setup. Every test isolates the script under test from the real
# environment by prepending a stub directory to PATH.

bats_require_minimum_version 1.5.0

setup_common() {
  REPO_ROOT="$(cd -- "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SCRIPTS="${REPO_ROOT}/scripts"
  STUB_DIR="${BATS_TEST_TMPDIR}/stubs"
  mkdir -p "$STUB_DIR"
  PATH="${STUB_DIR}:${PATH}"
  export REPO_ROOT SCRIPTS STUB_DIR PATH
  # Keep retry/backoff tests instant.
  export RETRY_BASE_DELAY=0
}

# stub NAME BODY — write an executable stub onto the front of PATH.
stub() {
  local name="$1"
  shift
  {
    echo '#!/usr/bin/env bash'
    printf '%s\n' "$@"
  } >"${STUB_DIR}/${name}"
  chmod +x "${STUB_DIR}/${name}"
}

# stub_calls NAME — path to the call log a recording stub writes to.
stub_calls() {
  printf '%s/%s.calls' "$BATS_TEST_TMPDIR" "$1"
}
