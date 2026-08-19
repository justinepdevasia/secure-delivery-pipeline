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

@test "the fallback skips signature and attestation versions" {
  # Signatures and attestations are published after the image and would otherwise
  # be picked as "latest" — and then fail verification, because they are not it.
  local image_digest="sha256:4444444444444444444444444444444444444444444444444444444444444444"
  stub docker "exit 1"
  cat >"${STUB_DIR}/gh" <<GHEOF
#!/usr/bin/env bash
# Emulate: newest first, with a signature artifact ahead of the image.
payload='[
  {"name":"sha256:9999999999999999999999999999999999999999999999999999999999999999",
   "metadata":{"container":{"tags":["sha256-4444.sig"]}}},
  {"name":"sha256:8888888888888888888888888888888888888888888888888888888888888888",
   "metadata":{"container":{"tags":[]}}},
  {"name":"${image_digest}",
   "metadata":{"container":{"tags":["6ed1ec811b0fea942b514eb32914488aaa54c3f7"]}}}
]'
for arg in "\$@"; do
  case "\$arg" in --jq) next=1 ;; *) if [ "\${next:-}" = 1 ]; then filter="\$arg"; next=0; fi ;; esac
done
printf '%s' "\$payload" | jq -r "\$filter"
GHEOF
  chmod +x "${STUB_DIR}/gh"
  run --separate-stderr "$RESOLVE" --image "$IMAGE" --tag abc123 --attempts 1 \
    --fallback-latest --owner acme --package app/api --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e --arg d "$image_digest" '.digest == $d and .source == "fallback-latest"'
}

@test "--fallback-latest without --package is a usage error" {
  stub docker "exit 1"
  run "$RESOLVE" --image "$IMAGE" --tag abc123 --attempts 1 --fallback-latest --owner acme
  [ "$status" -eq 2 ]
}

# A gh stub that answers both uses: `gh api` for the version list, and
# `gh attestation verify`, which verify-supply-chain.sh calls for provenance and
# SBOM. A stub that only handles the first makes every candidate look unverifiable.
stub_gh_candidates() {
  cat >"${STUB_DIR}/gh" <<'GHEOF'
#!/usr/bin/env bash
if [ "${1:-}" != "api" ]; then
  exit 0
fi
payload='[
  {"name":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
   "metadata":{"container":{"tags":["1111111111111111111111111111111111111111"]}}},
  {"name":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
   "metadata":{"container":{"tags":["2222222222222222222222222222222222222222"]}}}
]'
filter="."
while [ $# -gt 0 ]; do
  if [ "$1" = "--jq" ]; then filter="$2"; shift; fi
  shift
done
printf '%s' "$payload" | jq -r "$filter"
GHEOF
  chmod +x "${STUB_DIR}/gh"
}

@test "--verify-repo skips a candidate that does not verify" {
  # The newest published image can be one whose build pushed and then failed
  # before signing. Deploying it would be caught by the gate later; not choosing
  # it in the first place is better.
  stub docker "exit 1"
  stub_gh_candidates
  stub cosign "case \"\$*\" in *aaaa*) exit 1 ;; *) exit 0 ;; esac"
  run --separate-stderr "$RESOLVE" --image "$IMAGE" --tag abc123 --attempts 1 \
    --fallback-latest --owner acme --package app/api --verify-repo acme/app --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.digest == "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"'
}

@test "--verify-repo takes the newest candidate when it verifies" {
  stub docker "exit 1"
  stub_gh_candidates
  stub cosign "exit 0"
  run --separate-stderr "$RESOLVE" --image "$IMAGE" --tag abc123 --attempts 1 \
    --fallback-latest --owner acme --package app/api --verify-repo acme/app --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.digest == "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"'
}

@test "exits 4 when no fallback candidate verifies" {
  stub docker "exit 1"
  stub_gh_candidates
  stub cosign "exit 1"
  run "$RESOLVE" --image "$IMAGE" --tag abc123 --attempts 1 \
    --fallback-latest --owner acme --package app/api --verify-repo acme/app
  [ "$status" -eq 4 ]
  [[ "$output" == *"passed verification"* ]]
}

@test "a verifier that cannot run is not mistaken for an unverifiable image" {
  # cosign missing must fail loudly, not silently reject every candidate — which
  # is exactly what happened when the deploy ran the verifier before installing it.
  command -v cosign >/dev/null && skip "cosign is present in this environment"
  stub docker "exit 1"
  stub_gh_candidates
  run "$RESOLVE" --image "$IMAGE" --tag abc123 --attempts 1 \
    --fallback-latest --owner acme --package app/api --verify-repo acme/app
  [ "$status" -eq 1 ]
  [[ "$output" == *"verifier could not run"* ]]
}
