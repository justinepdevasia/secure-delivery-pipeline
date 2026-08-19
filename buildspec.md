# BUILD SPEC — `secure-delivery-pipeline`

A portfolio repository demonstrating GitHub Actions CI/CD, software supply chain security,
Bash and Python automation, and AWS/EKS delivery — **built and verified entirely inside
GitHub Actions**. No cloud account, no local Docker, no local Kubernetes, no cost.

**Fill these in before starting:**

| Placeholder | Value |
|---|---|
| `{{GITHUB_USER}}` | _your github username_ |
| `{{REPO_NAME}}` | `secure-delivery-pipeline` |
| `{{AWS_REGION}}` | `us-east-1` |

---

## How to use this document

This is the complete specification. Read it end to end before writing anything.

**Prerequisites:** the repo must be public (OpenSSF Scorecard and free GHCR require it),
and `gh` must be authenticated with `repo` and `workflow` scopes.

**Working agreement:**

- Build in the order given in §12, one branch per phase.
- After each phase, push and verify with `gh run watch --exit-status`. Do not open the PR
  or start the next phase until the run is green.
- Never assert that something works without a green run to point at.
- Never write an action SHA or image digest from memory — resolve it (§0, rules 1 and 2).
- Pause for review after phase 3, after phase 6, and after phase 13.
- Ask before force-pushing, rewriting history, or merging to `main`.

**Suggested opening instruction:**

> Read BUILD_SPEC.md in full. Follow §0 exactly: everything is verified in GitHub Actions,
> never locally, and the CI run is the only source of truth. Work through §12 one branch at
> a time, iterating with `gh run watch` and `gh run view --log-failed` until each phase is
> green. Resolve every action SHA with `gh api`. Start with phases 1–3, then stop.

---

## 0. Operating model — read this first

**Nothing runs on the developer's machine.** The only local tools are `git`, an editor, and
the `gh` CLI. Every build, test, emulator, cluster, and scan runs on a GitHub-hosted runner.

**The CI run is the only source of truth.** Never state that something "works" or "should
pass" without a green run to point at. If a workflow has not run, its status is unknown.

### The development loop

Work on a branch, one phase at a time, and drive it with the `gh` CLI:

```bash
git switch -c phase/03-ci-python
# ...write files...
git add -A && git commit -m "feat(ci): add python lint, test and coverage workflow"
git push -u origin HEAD

gh run watch --exit-status              # blocks until the run finishes
gh run view --log-failed                # only the failing steps, not the whole log
```

On failure: read `--log-failed`, fix, amend or add a commit, push, watch again. Repeat
until green. **Only then** open the PR and merge. Do not start the next phase with a red
branch behind you.

To re-run a workflow without a code change: `gh workflow run <file> --ref <branch>`, then
`gh run watch`.

### Making failures readable

Because there is no local reproduction, workflows must be self-diagnosing:

- `set -euo pipefail` and `set -x` in every non-trivial `run:` block.
- Write meaningful output to `$GITHUB_STEP_SUMMARY`, not just stdout.
- `if: failure()` steps that dump container logs, `kubectl describe`, `kubectl get events
  --sort-by=.lastTimestamp`, and `terraform show` before the job exits.
- `actions/upload-artifact` with `if: always()` for rendered manifests, plan files, scan
  reports, and emulator logs.
- Name every step. A failure on "Run" tells you nothing; a failure on
  "Wait for Floci health endpoint" tells you everything.

### A scratch workflow

Keep `.github/workflows/scratch.yml` — `workflow_dispatch` only — as a throwaway harness
for testing one step in isolation without running the full pipeline. Delete it in the final
phase before publishing.

### Rules that outrank convenience

1. **Every third-party action pinned to a full 40-char commit SHA**, version in a trailing
   comment: `uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2`.
   Resolve each with `gh api repos/OWNER/REPO/commits/TAG --jq .sha`. **Never write a SHA
   from memory** — a fabricated one fails immediately and wastes a full run cycle.
2. **Every container image pinned by digest**, including the emulator. This repo is about
   supply chain security; a floating tag anywhere in it is a self-inflicted wound.
3. **Explicit least-privilege `permissions:`** on every workflow. Top-level `contents: read`;
   elevate per-job only.
4. **Zero repo secrets.** Everything must be green on a fresh clone with no configuration.
5. **No inline scripting over ~15 lines in a workflow.** Anything longer belongs in
   `scripts/` or `tools/`, where it can be linted and unit-tested (§5).
6. **Conventional commits, one phase per branch.** The git history is part of the artifact.

---

## 1. What is real vs. emulated

Be explicit about this in the README rather than blurring it.

| Layer | Status |
|---|---|
| Build, scan, SBOM, provenance, signing, **verification** | **Real.** GHCR + Sigstore + GitHub attestations, independently verifiable by anyone |
| Bash and Python automation | **Real.** Linted, unit-tested, and executed by the pipeline itself |
| AWS API surface (IAM, STS, ECR, EKS, Secrets Manager, CloudWatch) | **Emulated in-runner** via Floci — real `terraform apply`, real `docker push`, real cluster |
| Kubernetes | **Real k3s** spun up by the emulator's EKS implementation — real `helm install`, real rollout |
| Production values (IRSA, ALB Controller, multi-AZ) | **Static validation only** — schema + policy tested, never applied |

---

## 2. Repository layout

```
{{REPO_NAME}}/
├── .github/
│   ├── workflows/
│   │   ├── ci-python.yml
│   │   ├── ci-dotnet.yml
│   │   ├── ci-scripts.yml           # shellcheck, shfmt, bats, mypy, pytest
│   │   ├── reusable-build-attest.yml
│   │   ├── security.yml
│   │   ├── manifests.yml
│   │   ├── infra-test.yml
│   │   ├── infra-apply-emulated.yml
│   │   ├── deploy-eks-emulated.yml
│   │   ├── release.yml
│   │   └── scratch.yml              # deleted before publishing
│   ├── actions/
│   │   ├── setup-floci/action.yml
│   │   ├── verify-provenance/action.yml
│   │   └── datadog-deployment-marker/action.yml
│   ├── dependabot.yml
│   ├── CODEOWNERS
│   └── pull_request_template.md
├── services/
│   ├── api-python/
│   └── api-dotnet/
├── scripts/                         # Bash — see §5
│   ├── lib/common.sh
│   ├── preflight.sh
│   ├── wait-for-endpoint.sh
│   ├── wait-for-rollout.sh
│   ├── smoke-test.sh
│   ├── verify-supply-chain.sh
│   ├── promote-image.sh
│   ├── audit-action-pins.sh
│   └── collect-diagnostics.sh
├── scripts/tests/                   # bats-core tests for the Bash above
├── tools/                           # Python — see §5
│   ├── pyproject.toml
│   ├── src/pipeline_tools/
│   │   ├── dora.py
│   │   ├── datadog_gate.py
│   │   ├── sbom_diff.py
│   │   ├── workflow_audit.py
│   │   └── pr_comment.py
│   └── tests/
├── charts/api/
│   ├── values.yaml
│   ├── values-emulator.yaml
│   └── values-prod.yaml
├── policy/
├── schemas/
├── infra/
│   ├── aws/
│   │   ├── tests/*.tftest.hcl
│   │   └── emulator.tfvars
│   └── datadog/
├── docs/
└── README.md
```

---

## 3. Applications

Keep both small — nobody is grading the application code.

**`services/api-python`** — Python 3.12 FastAPI. Endpoints `/healthz`, `/readyz`,
`GET /api/v1/orders` (fixture data), `POST /api/v1/orders` (Pydantic validation),
`/metrics`. Structured JSON logging. `pytest` + `httpx`, `--cov-fail-under=85`.
`ruff check`, `ruff format --check`, `mypy --strict`. Committed lockfile — mandatory.

Add one module that reads config from Secrets Manager via boto3 with
`endpoint_url=os.getenv("AWS_ENDPOINT_URL")`. This gives a genuine AWS-SDK code path that
gets integration-tested against the emulator.

**`services/api-dotnet`** — .NET 8 minimal API, same three endpoints, xUnit tests,
`dotnet format --verify-no-changes`. Under 100 lines. It exists to prove multi-runtime
pipeline handling, which maps to their .NET environment.

**Both Dockerfiles** — multi-stage, final stage distroless **pinned by digest**, non-root
`USER`, OCI labels (`source`, `revision`, `created`). Distroless keeps the Trivy gate clean.

---

## 4. `setup-floci` composite action

Used by the infra and deploy workflows.

```yaml
# .github/actions/setup-floci/action.yml  (abridged)
runs:
  using: composite
  steps:
    - shell: bash
      run: |
        set -euo pipefail
        docker run -d --name floci -p 4566:4566 -u root \
          -v /var/run/docker.sock:/var/run/docker.sock \
          floci/floci@sha256:<PINNED_DIGEST>
        "${GITHUB_ACTION_PATH}/../../../scripts/wait-for-endpoint.sh" \
          --url http://localhost:4566/_localstack/health --timeout 90
    - shell: bash
      run: |
        {
          echo "AWS_ENDPOINT_URL=http://localhost:4566"
          echo "AWS_ACCESS_KEY_ID=test"
          echo "AWS_SECRET_ACCESS_KEY=test"
          echo "AWS_DEFAULT_REGION={{AWS_REGION}}"
        } >> "$GITHUB_ENV"
```

Resolve the digest once with `docker buildx imagetools inspect floci/floci:<version>` in a
scratch run, then hard-code it. Pair every use with an `if: always()` step running
`docker logs floci` so failures are diagnosable from the Actions log alone.

---

## 5. Scripting — Bash and Python automation

The job description asks for Bash scripting and a development background. This section is
where that is demonstrated, so treat it as a first-class deliverable rather than glue.

**The governing rule: every script here must be genuinely called by a workflow.** A
`scripts/` directory full of code nothing invokes reads as padding. If a workflow needs
logic, it goes in a script and the workflow calls it — that is also what keeps the YAML
readable and the logic testable.

### 5.1 Bash — `scripts/`

Standards, enforced in CI:

- `#!/usr/bin/env bash` and `set -euo pipefail`; set `IFS=$'\n\t'` where word-splitting matters.
- Quote every expansion. Use `[[ ]]`, `local` for all function variables, `readonly` for constants.
- `usage()` plus `--help`; parse flags properly (`while [[ $# -gt 0 ]]` + `case`), never positional-only.
- Meaningful exit codes: `0` success, `1` generic failure, `2` usage error, `3` timeout,
  `4` verification failure. Document them in the header comment.
- `trap cleanup EXIT` with `mktemp -d` for scratch space — no stray files, no leaked containers.
- A `--dry-run` flag on anything that mutates state, and a `--json` output mode on anything
  a workflow needs to parse. Never parse human-readable output in a pipeline.
- `log_info` / `log_warn` / `log_error` helpers in `scripts/lib/common.sh`, writing to stderr
  with timestamps, so stdout stays machine-parseable.
- Idempotent: safe to run twice. Retries use exponential backoff, never a bare `sleep`.
- `shellcheck --severity=style` clean and `shfmt -d -i 2 -ci` clean.

Scripts to build:

| Script | What it does |
|---|---|
| `lib/common.sh` | Logging, `require_cmd`, `retry_with_backoff`, `die` |
| `preflight.sh` | Assert required CLIs exist and meet minimum versions; fail fast with a clear message |
| `wait-for-endpoint.sh` | Poll an HTTP endpoint until healthy, with timeout and backoff; exit 3 on timeout |
| `wait-for-rollout.sh` | Wrap `kubectl rollout status`; on failure call `collect-diagnostics.sh` before exiting |
| `smoke-test.sh` | Run a curl pod against `/healthz` and `/api/v1/orders`; assert status code and JSON shape with `jq -e` |
| `verify-supply-chain.sh` | `cosign verify` + `gh attestation verify` against a digest; `--json` output; exit 4 on verification failure |
| `promote-image.sh` | Retag and push between registries **by digest, never by tag**; refuse to run if the source digest is unsigned |
| `audit-action-pins.sh` | Parse every `uses:` in `.github/workflows/`, flag anything not pinned to a 40-char SHA, and resolve the current SHA for each tag to report drift |
| `collect-diagnostics.sh` | Gather `kubectl describe`, pod logs, events, and `docker logs floci` into a tarball for `upload-artifact` |

`audit-action-pins.sh` is the standout: it enforces the repo's own central security rule,
in Bash, in CI. Wire it into `security.yml` as a required check and mention it in the README.

### 5.2 Bash unit tests — `scripts/tests/`

Use **bats-core**. Testing Bash is rare enough that it is a real differentiator, and it is
the only way to verify this code without running it locally.

Cover: flag parsing, `--help` exits 0, missing required args exit 2, timeout paths exit 3,
retry backoff stops after N attempts, `--dry-run` performs no mutation. Stub external
commands (`kubectl`, `aws`, `cosign`) by prepending a fixture directory to `PATH` — this
also proves you understand how to isolate a script from its environment.

### 5.3 Python — `tools/`

A proper installable package, not loose files. `pyproject.toml` with `console_scripts`
entry points so workflows call `dora-metrics` rather than `python path/to/file.py`.

Standards: `argparse` (or Typer) with subcommands, full type hints, `mypy --strict`,
`ruff`, structured logging to stderr, `--json` output, explicit exit codes, no bare
`except`, HTTP calls wrapped with retry and timeout. `pytest` with `responses`/`respx` for
API mocking — no network access in tests. Target ≥85% coverage on this package too.

| Module | What it does |
|---|---|
| `dora.py` | Compute deploy frequency, lead time for changes, change failure rate and MTTR from the GitHub API; emit Markdown for the step summary and JSON for artifacts |
| `datadog_gate.py` | Query monitor state for a service/env and fail the deploy if any critical monitor is alerting; `DD_DRY_RUN` logs the exact request instead of sending |
| `sbom_diff.py` | Diff two CycloneDX SBOMs and report added, removed and upgraded dependencies; post the delta as a PR comment |
| `workflow_audit.py` | Static checks the off-the-shelf linters miss: every job declares `permissions`, no `pull_request_target` with a checkout of untrusted refs, no `${{ github.event.*.body }}` interpolated into `run:` |
| `pr_comment.py` | Sticky PR comment helper (find-by-marker, update or create) used by the plan, SBOM diff and DORA jobs |

`sbom_diff.py` is the strongest of these for this role: it turns SBOM generation from an
artifact nobody reads into a supply-chain control that speaks up on every PR.

### 5.4 `ci-scripts.yml`

Triggered on `scripts/**`, `tools/**`, and `.github/workflows/**`:

```
shellcheck --severity=style scripts/**/*.sh
shfmt -d -i 2 -ci scripts/
bats scripts/tests/
ruff check tools/ && mypy --strict tools/src
pytest tools/tests --cov=pipeline_tools --cov-fail-under=85
scripts/audit-action-pins.sh --check
python -m pipeline_tools.workflow_audit .github/workflows/
```

Put a coverage and lint summary in `$GITHUB_STEP_SUMMARY`. Add a README section listing
each script with its purpose, flags and exit codes — a reviewer skimming that table sees
the scripting competence immediately without opening a file.

---

## 6. Workflows

### `ci-python.yml` / `ci-dotnet.yml`
`pull_request` + `push` to `main`. `paths:` filtered per service. `concurrency` with
`cancel-in-progress`. Python matrix over 3.11/3.12. Dependency cache keyed on lockfile hash.
Coverage summary to `$GITHUB_STEP_SUMMARY`. An emulator-backed integration test job for the
Secrets Manager code path.

### `reusable-build-attest.yml` — the centerpiece, fully real
`workflow_call`, inputs `service_path` / `image_name` / `dockerfile`.
Job permissions: `contents: read`, `packages: write`, `id-token: write`, `attestations: write`.

1. Buildx build, load locally — do not push yet.
2. **Trivy scan before push**: `severity: CRITICAL,HIGH`, `ignore-unfixed: true`,
   `exit-code: 1`. A vulnerable image never reaches a registry.
3. Push to `ghcr.io/{{GITHUB_USER}}/{{REPO_NAME}}/<service>`, tagged by commit SHA.
4. **SBOM** via Syft — CycloneDX **and** SPDX JSON. Run `sbom-diff` against the previous
   release and post the delta as a PR comment.
5. `actions/attest-sbom` against the digest.
6. `actions/attest-build-provenance` against the digest — real SLSA v1 provenance.
7. `cosign sign --yes <image>@<digest>` — keyless, no key material.
8. **Verify what you just produced** via `scripts/verify-supply-chain.sh --json`, dumping
   the result to the step summary. Fails closed.
9. `outputs: digest`.

Step 8 is the differentiator — plenty of pipelines sign, very few gate on verification.

### `security.yml`
`pull_request`, `push` to `main`, weekly `schedule`.
CodeQL (`python` + `csharp`, `security-extended`); Dependency Review guarded with
`if: github.event_name == 'pull_request'`; pip-audit; Gitleaks over full history; Trivy
config; Checkov; `actionlint` + `zizmor`; **`scripts/audit-action-pins.sh`**;
**`workflow_audit`**; OpenSSF Scorecard + badge. All SARIF uploaded.

### `manifests.yml`
On `charts/**` or `policy/**` changes: `helm lint`, `helm template` for both value files,
`kubeconform -strict` with vendored CRD schemas from `schemas/`, `kube-linter`,
`conftest test --policy policy/`, `trivy config`. Upload rendered manifests as artifacts.

Write 4–6 **of your own** rego policies: resource limits required, non-root required, no
`:latest` images, liveness and readiness probes required.

### `infra-test.yml` — credential-free Terraform testing
`terraform fmt -check`, `init -backend=false`, `validate`, `tflint`, `checkov`, `tfsec`,
then **`terraform test`** with `mock_provider "aws" {}` in `infra/aws/tests/*.tftest.hcl`:

```hcl
mock_provider "aws" {}

run "oidc_trust_policy_is_scoped" {
  command = plan
  assert {
    condition     = !strcontains(data.aws_iam_policy_document.gha_trust.json, ":*")
    error_message = "Trust policy must not use a wildcard subject claim"
  }
}
```

This matters because the emulator does not enforce IAM. `apply` succeeding proves the graph
resolves; only these assertions prove the policy is correctly scoped.

### `infra-apply-emulated.yml`
`setup-floci`, then a genuine `terraform apply -auto-approve -var-file=emulator.tfvars`,
then assertions via the AWS CLI (`aws iam get-role`, `aws ecr describe-repositories`,
`aws secretsmanager list-secrets`) written to the step summary, then `terraform destroy`.
Keep emulator endpoints in `emulator.tfvars` and a separate provider alias — never let them
leak into the production configuration.

### `deploy-eks-emulated.yml`
The showpiece. `setup-floci`, then:

1. **Verify supply chain** — `scripts/verify-supply-chain.sh` against the build digest.
   Fails closed. Genuine.
2. **ECR** — `aws ecr create-repository`, `get-login-password | docker login`, then
   `scripts/promote-image.sh` to push by digest.
3. **EKS** — `aws eks create-cluster`, poll until ACTIVE, `aws eks update-kubeconfig`.
   Backed by real k3s with a live Kubernetes API server.
4. **Deploy** — `helm upgrade --install api ./charts/api -f charts/api/values-emulator.yaml
   --set image.digest=<digest> --wait --timeout 5m --atomic`, then `wait-for-rollout.sh`.
5. **Smoke test** — `scripts/smoke-test.sh`.
6. **Rollback on failure** — `if: failure()` runs `helm rollback` and
   `scripts/collect-diagnostics.sh`, uploading the bundle as an artifact.
7. **Datadog gate and marker** — `datadog_gate` before deploy, marker after; both
   `DD_DRY_RUN` by default.
8. **DORA metrics** — `dora-metrics` writes the table to the step summary.

Name jobs and steps honestly (`deploy-emulated`, `create-emulated-eks-cluster`) so nobody
scanning the Actions tab concludes you have a live AWS account.

### `release.yml`
Tag-triggered `release-please`, attaching both SBOMs and the rendered manifest bundle.

---

## 7. Helm values — two files, kept distinct

**`values-emulator.yaml`** — actually deployed to k3s. 1 replica, `ClusterIP`, no ingress,
no IRSA annotation, small resource requests.

**`values-prod.yaml`** — never applied, validated on every PR, written to demonstrate real
EKS knowledge:

- **IRSA** ServiceAccount annotation `eks.amazonaws.com/role-arn`
- **AWS Load Balancer Controller** ingress annotations: `scheme`, `target-type: ip`,
  `healthcheck-path`, `ssl-policy`, `certificate-arn`
- **topologySpreadConstraints** over `topology.kubernetes.io/zone`,
  `whenUnsatisfiable: DoNotSchedule`
- **PodDisruptionBudget** `minAvailable: 2`, pod anti-affinity
- **HPA** on CPU plus a Datadog external metric
- **securityContext**: `runAsNonRoot`, `readOnlyRootFilesystem`,
  `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`,
  `seccompProfile: RuntimeDefault`
- Requests **and** limits, with a comment explaining the ratio
- **ExternalSecret** sourcing from AWS Secrets Manager
- Datadog admission controller labels and `tags.datadoghq.com/{env,service,version}`

IRSA and the ALB Controller will not function under the emulator — that is expected and is
exactly why they live in a separate, statically-validated file. Note this in a comment at
the top of the file.

---

## 8. `infra/`

**`infra/aws/`** — VPC, EKS cluster and node group, Karpenter `NodePool`/`EC2NodeClass`,
ECR with immutable tags and scan-on-push, GitHub OIDC provider, and IAM roles with tightly
scoped trust policies:

```hcl
values = [
  "repo:{{GITHUB_USER}}/{{REPO_NAME}}:environment:production",
  "repo:{{GITHUB_USER}}/{{REPO_NAME}}:ref:refs/heads/main",
]
```

Add a comment noting that a bare `repo:owner/name:*` wildcard is the common
misconfiguration that lets any fork PR assume the role. Pin the provider version. Give
every variable a default so `validate` and `test` pass with no tfvars.

**`infra/datadog/`** — monitors for error rate, p99 latency, pod restarts, deploy failure;
two SLOs with error budgets; a dashboard. Give `api_key`/`app_key` empty-string defaults so
`validate` passes credential-free. Never `plan` or `apply`.

---

## 9. Anti-failure notes — read before writing any workflow

Each of these costs a full push-and-wait cycle if missed.

| Risk | Fix |
|---|---|
| Fabricated action SHAs | `gh api repos/OWNER/REPO/commits/TAG --jq .sha` for every one |
| Emulator not ready when the next step runs | `wait-for-endpoint.sh` against `/_localstack/health`; never `sleep 10` and hope |
| Docker-backed services failing | Emulator needs `-u root` and `-v /var/run/docker.sock:/var/run/docker.sock` |
| k3s slow to become ACTIVE | Poll `aws eks describe-cluster` with a generous timeout |
| Runner disk exhaustion | k3s + registry + app images add up; `docker system prune -af` or free space first |
| `dependency-review-action` on push events | `if: github.event_name == 'pull_request'` |
| `kubeconform` failing on CRDs | Vendor CRD schemas into `schemas/`; avoid `-ignore-missing-schemas` |
| Trivy HIGH CVEs in base image | Distroless pinned by digest; `ignore-unfixed: true`; dated `.trivyignore` entries |
| Checkov flooding on EKS Terraform | Fix real findings; inline `#checkov:skip=CKV_AWS_XXX: reason`. Never blanket `--soft-fail` |
| CodeQL `csharp` build failure | `setup-dotnet` first, ensure `dotnet build` succeeds standalone |
| `shellcheck` failing on `source scripts/lib/common.sh` | Add `# shellcheck source=scripts/lib/common.sh` above each source line |
| bats not installed on the runner | Install via `bats-core/bats-action` (SHA-pinned) or `npm i -g bats` |
| Scripts not executable after clone | `git update-index --chmod=+x scripts/*.sh`; assert with a `test -x` check in `ci-scripts.yml` |
| Gitleaks on placeholder account IDs | Use `000000000000` (the emulator default) or `.gitleaksignore` |
| Emulator failures invisible in logs | `if: always()` step running `docker logs floci` |

---

## 10. README — the actual deliverable

1. One paragraph: what this is and why it exists.
2. Badges: CI, CodeQL, Scorecard, license.
3. Mermaid architecture diagram and pipeline flow: commit → lint/test → build → scan →
   push → SBOM → attest → sign → verify → ECR → EKS → helm → smoke → rollback.
4. **Supply chain controls table** — Control | Implementation | Threat mitigated. Rows:
   dependency confusion, compromised third-party action, tampered image, leaked credential,
   malicious commit, vulnerable base image.
5. **Automation reference** — a table of every script and CLI tool with its purpose, key
   flags and exit codes. This is where the Bash and Python competence becomes visible at a
   glance.
6. **"What is real and what is emulated"**, placed high, not buried:

   > The supply chain pipeline is fully operational: images are built, scanned, signed and
   > attested on every push to `main`, and the signatures are independently verifiable with
   > `gh attestation verify`. The AWS and Kubernetes layers run against a local AWS emulator
   > inside the GitHub Actions runner — Terraform genuinely applies, images genuinely push
   > to an ECR-backed registry, and Helm genuinely deploys to a real Kubernetes API server —
   > but no AWS account is involved. Production values (IRSA, ALB Controller, multi-AZ
   > spread) are schema- and policy-validated rather than applied.

   Include a copy-pasteable `gh attestation verify` command so a reviewer can confirm the
   real half themselves.
7. Workflow reference table: file | trigger | purpose | permissions.
8. Screenshots in `docs/images/`: attestation verification passing, the EKS deploy job,
   a blocked PR, a rollback.
9. `docs/threat-model.md` expands item 4 into prose; `docs/architecture.md` covers data flow.

---

## 11. Demonstration PRs — do these last, they are the best part

Real PRs, opened and closed, living in the history:

1. **`demo/vulnerable-dependency`** — a package with a known CVE; Dependency Review and
   Trivy block it.
2. **`demo/leaked-secret`** — a fake credential; Gitleaks blocks it.
3. **`demo/unpinned-action`** — one action switched to a floating tag; your own
   `audit-action-pins.sh` flags it.
4. **`demo/policy-violation`** — resource limits removed from the chart; your own conftest
   policy fails the render.
5. **`demo/failed-deploy`** — a broken readiness probe; the emulated EKS deploy fails,
   `helm rollback` fires, and `collect-diagnostics.sh` uploads the evidence.

Close each with a comment explaining what the pipeline caught, and link them from the
README. Note that PRs 3 and 4 are caught by controls you wrote yourself.

---

## 12. Build order — one branch per phase, green before merge

1. Skeleton, README stub, license, `.gitignore`.
2. Python service + tests.
3. `ci-python.yml`.
4. `scripts/lib/common.sh`, `preflight.sh`, `wait-for-endpoint.sh` + bats tests +
   `ci-scripts.yml` (shellcheck, shfmt, bats).
5. Dockerfile (distroless, digest-pinned).
6. `reusable-build-attest.yml` — build, scan, push, SBOM, attest, sign, **verify** via
   `verify-supply-chain.sh`.
7. `tools/` package skeleton + `workflow_audit.py` + `audit-action-pins.sh`; extend
   `ci-scripts.yml` with ruff, mypy, pytest.
8. `security.yml`, wiring in the two audit tools above.
9. Helm chart + both value files; `policy/` rego + `manifests.yml`.
10. .NET service + `ci-dotnet.yml`.
11. `infra/aws/` + `infra-test.yml` (mocked providers).
12. `setup-floci` action + `infra-apply-emulated.yml`.
13. `deploy-eks-emulated.yml` — ECR push, EKS create, helm, `wait-for-rollout.sh`,
    `smoke-test.sh`, rollback + `collect-diagnostics.sh`.
14. `sbom_diff.py`, `datadog_gate.py`, `dora.py`, `pr_comment.py` + `infra/datadog/`.
15. Governance: CODEOWNERS, Dependabot, rulesets, SECURITY.md, PR template.
16. README, automation reference table, diagrams, threat model, screenshots. Delete
    `scratch.yml`.
17. The five demonstration PRs.

Phases 12 and 13 are the highest-risk. Expect several red runs; that is normal and is why
the diagnostic steps in §0 exist.

---

## 13. Acceptance checklist

- [ ] `grep -rn "uses:" .github/ | grep -v "@[0-9a-f]\{40\}"` returns only local `./.github/actions` refs
- [ ] No image reference anywhere uses a floating tag
- [ ] Every workflow has an explicit `permissions:` block
- [ ] Repo has **zero** configured secrets and every workflow is green
- [ ] No workflow contains an inline `run:` block longer than ~15 lines
- [ ] Every script in `scripts/` and every module in `tools/` is invoked by a workflow
- [ ] `shellcheck --severity=style` and `shfmt -d` clean; all bats tests pass
- [ ] `mypy --strict tools/src` clean; `tools/` coverage ≥85%
- [ ] Every script supports `--help` and documents its exit codes
- [ ] `terraform test` passes with mocked providers, with at least three security assertions
- [ ] `terraform apply` succeeds against the emulator, is asserted, then destroyed
- [ ] A Helm release genuinely rolls out and the smoke test passes
- [ ] `helm template ... | kubeconform -strict` passes for both value files
- [ ] At least one conftest policy is your own
- [ ] `gh attestation verify` succeeds against the published GHCR image
- [ ] README includes the automation reference table and the real-vs-emulated section
- [ ] `scratch.yml` deleted
- [ ] Git history >40 commits, conventional format, no mega-commit