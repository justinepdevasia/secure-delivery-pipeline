#!/usr/bin/env bats
# Unit tests for scripts/render-manifests.sh — helm, kubeconform, kube-linter and
# conftest are all stubbed, so these run offline in milliseconds. The real chart
# is validated by manifests.yml against the real tools.

load helper

setup() {
  setup_common
  RENDER="${SCRIPTS}/render-manifests.sh"
  VALUES="${BATS_TEST_TMPDIR}/values.yaml"
  CHART="${BATS_TEST_TMPDIR}/chart"
  OUT="${BATS_TEST_TMPDIR}/rendered.yaml"
  mkdir -p "$CHART"
  echo "replicaCount: 1" >"$VALUES"
  export RENDER VALUES CHART OUT
}

stub_tools() {
  stub helm "echo 'kind: Deployment'"
  stub kubeconform "exit ${1:-0}"
  stub kube-linter "exit ${2:-0}"
  stub conftest "exit ${3:-0}"
}

@test "--help exits 0 and documents exit code 4" {
  run "$RENDER" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"4  a validation check failed"* ]]
}

@test "missing --values is a usage error" {
  run "$RENDER" --chart "$CHART"
  [ "$status" -eq 2 ]
}

@test "a values file that does not exist is a usage error" {
  run "$RENDER" --chart "$CHART" --values "${BATS_TEST_TMPDIR}/absent.yaml"
  [ "$status" -eq 2 ]
}

@test "an unknown flag is a usage error" {
  run "$RENDER" --chart "$CHART" --values "$VALUES" --bogus
  [ "$status" -eq 2 ]
}

@test "renders and passes when every check succeeds" {
  stub_tools 0 0 0
  run "$RENDER" --chart "$CHART" --values "$VALUES" --out "$OUT"
  [ "$status" -eq 0 ]
  grep -q "kind: Deployment" "$OUT"
}

@test "exits 4 when kubeconform fails" {
  stub_tools 1 0 0
  run "$RENDER" --chart "$CHART" --values "$VALUES" --out "$OUT"
  [ "$status" -eq 4 ]
  [[ "$output" == *"kubeconform failed"* ]]
}

@test "exits 4 when conftest fails" {
  stub_tools 0 0 1
  run "$RENDER" --chart "$CHART" --values "$VALUES" --out "$OUT"
  [ "$status" -eq 4 ]
  [[ "$output" == *"conftest failed"* ]]
}

@test "reports every failing check, not just the first" {
  stub_tools 1 1 1
  run --separate-stderr "$RENDER" --chart "$CHART" --values "$VALUES" --out "$OUT" --json
  [ "$status" -eq 4 ]
  echo "$output" | jq -e '.failures == 3 and .ok == false'
}

@test "--skip omits a check without failing" {
  stub_tools 0 0 0
  run --separate-stderr "$RENDER" --chart "$CHART" --values "$VALUES" --out "$OUT" \
    --skip kube-linter --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '[.checks[] | select(.status == "skipped")] | length == 1'
}

@test "--json reports the rendered path" {
  stub_tools 0 0 0
  run --separate-stderr "$RENDER" --chart "$CHART" --values "$VALUES" --out "$OUT" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e --arg o "$OUT" '.rendered == $o and .ok == true'
}
