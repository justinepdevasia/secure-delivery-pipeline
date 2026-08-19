#!/usr/bin/env bats
# Unit tests for scripts/smoke-test.sh — kubectl is stubbed to return canned
# payloads, so the assertions themselves are what is under test.

load helper

setup() {
  setup_common
  SMOKE="${SCRIPTS}/smoke-test.sh"
  export SMOKE
}

# A kubectl stub that answers each endpoint with a canned body. Everything the
# script asks for goes through `kubectl run ... -- curl <url>`, so the URL is the
# last argument. Written as a file rather than through stub() because the bodies
# are JSON and would not survive another layer of quoting.
stub_kubectl_serving() {
  local orders="${1-}" health="${2-}"
  [[ -n "$orders" ]] || orders='{"items":[{"id":"ord-1","total_cents":10,"status":"pending"}],"count":1}'
  [[ -n "$health" ]] || health='{"status":"ok"}'

  cat >"${STUB_DIR}/kubectl" <<EOF
#!/usr/bin/env bash
url="\${@: -1}"
case "\$url" in
  *healthz) echo '${health}' ;;
  *readyz) echo '{"status":"ready","environment":"emulated","secrets_source":"secretsmanager"}' ;;
  */orders)
    if printf '%s' "\$*" | grep -q 'write-out'; then printf '422'; else echo '${orders}'; fi ;;
  *) echo '{}' ;;
esac
exit 0
EOF
  chmod +x "${STUB_DIR}/kubectl"
}

@test "--help exits 0 and documents exit code 4" {
  run "$SMOKE" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"4  an assertion failed"* ]]
}

@test "a missing --service is a usage error" {
  run "$SMOKE" --namespace default
  [ "$status" -eq 2 ]
}

@test "an unknown flag is a usage error" {
  run "$SMOKE" --service api --bogus
  [ "$status" -eq 2 ]
}

@test "passes against a healthy service" {
  stub_kubectl_serving
  run --separate-stderr "$SMOKE" --service api-api --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.ok == true and .failures == 0 and (.checks | length) == 4'
}

@test "exits 3 when the service never answers" {
  stub kubectl "exit 1"
  run --separate-stderr "$SMOKE" --service api-api --timeout 1 --json
  [ "$status" -eq 3 ]
  echo "$output" | jq -e '.ok == false and .reason == "unreachable"'
}

@test "exits 4 when healthz returns the wrong body" {
  stub_kubectl_serving '{"items":[],"count":0}' '{"status":"degraded"}'
  run --separate-stderr "$SMOKE" --service api-api --json
  [ "$status" -eq 4 ]
  echo "$output" | jq -e '[.checks[] | select(.check == "healthz")] | .[0].status == "fail"'
}

@test "exits 4 when the orders envelope count disagrees with the item list" {
  # A 200 with a plausible-looking body is exactly what a shape assertion is for.
  stub_kubectl_serving '{"items":[{"id":"ord-1","total_cents":10,"status":"pending"}],"count":7}'
  run --separate-stderr "$SMOKE" --service api-api --json
  [ "$status" -eq 4 ]
  echo "$output" | jq -e '[.checks[] | select(.check == "orders")] | .[0].status == "fail"'
}

@test "exits 4 when an order item is missing a documented field" {
  stub_kubectl_serving '{"items":[{"id":"ord-1"}],"count":1}'
  run --separate-stderr "$SMOKE" --service api-api --json
  [ "$status" -eq 4 ]
}

@test "targets the in-cluster Service DNS name, not an external address" {
  stub_kubectl_serving
  run --separate-stderr "$SMOKE" --service api-api --namespace prod --json
  echo "$stderr" | grep -q "api-api.prod.svc.cluster.local"
}
