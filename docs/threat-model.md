# Threat model

The README lists the controls. This says what each one is actually defending
against, how it would be defeated, and what it does not cover — because a
controls table with no stated limits is marketing.

## Scope

The asset being protected is **the integrity of what runs in the cluster**: that
the artifact deployed is the artifact that was built from the reviewed source, by
this repository's pipeline, and nothing else.

Everything downstream of that — runtime intrusion detection, network policy, data
protection — is out of scope here. So is the emulated AWS layer: the emulator does
not enforce IAM, and no claim is made that it does.

## Trust boundaries

| Boundary | Crossing it means |
| --- | --- |
| Pull request → CI runner | Untrusted content reaching a machine that holds a token |
| CI runner → GHCR | An artifact becoming pullable by anything with the reference |
| GHCR → cluster | An artifact becoming a running process |
| Repository → third-party action | Someone else's code running with our token |
| Repository → base image | Someone else's binaries inside our artifact |

Every control below sits on one of those five lines.

---

## T1 — Compromised third-party action

**How it happens.** An action is referenced by tag. The maintainer's account is
taken over, or a maintainer turns malicious, and `v4` is repointed at code that
reads `GITHUB_TOKEN` and exfiltrates it. Nothing in the repository changes; the
next run is compromised.

**Control.** Every `uses:` is pinned to a full 40-character commit SHA.
[`scripts/audit-action-pins.sh`](../scripts/audit-action-pins.sh) parses every
workflow and composite action and fails the build on anything that is not, and it
is a required status check. `--drift` additionally resolves each trailing
`# vX.Y.Z` comment through the API and reports pins that have fallen behind.

**What it does not cover.** A SHA that was already malicious when pinned. Pinning
freezes behaviour; it does not review it. It also means security fixes are not
picked up automatically, which is why Dependabot is configured — the pin and the
bot are two halves of one control.

**Demonstrated by** [`demo/unpinned-action`](../../pulls).

---

## T2 — Tampered or substituted image

**How it happens.** An image is referenced by tag. Between the scan and the
deploy, the tag is moved — by a race, a rebuild, or an attacker with registry
write access. The cluster pulls something that was never reviewed.

**Control.** Three layers.

1. Everything is referenced by digest: base images, the emulator, the deployed
   workload. `charts/api` templates render `image@sha256:...` whenever a digest is
   set, and the deploy always sets one.
2. [`scripts/resolve-image-digest.sh`](../scripts/resolve-image-digest.sh) resolves
   the tag to a digest **once**, at the start of the deploy. Everything downstream
   uses that digest, so a tag that moves mid-deploy cannot cause one artifact to
   be verified and a different one shipped.
3. [`scripts/verify-supply-chain.sh`](../scripts/verify-supply-chain.sh) checks the
   cosign signature and the GitHub provenance and SBOM attestations against that
   digest, and **exits 4** if any of them fail. The deploy stops there.

The signature identity is constrained to workflows in this repository
(`--certificate-identity-regexp ^https://github.com/OWNER/REPO/\.github/workflows/`),
so a validly signed image from somewhere else does not pass.

**What it does not cover.** An attacker who can run the legitimate workflow — for
example by merging malicious code — gets a legitimately signed image. Signing
proves origin, not intent. That is what review and CODEOWNERS are for.

---

## T3 — Vulnerable base image

**How it happens.** A base image accumulates CVEs between builds. The image is
built, pushed, and pulled by production before anyone scans it.

**Control.** Trivy runs on the locally built image **before the push**, gated at
`CRITICAL,HIGH` with `ignore-unfixed: true` and `exit-code: 1`. A vulnerable image
never gets a registry address. The runtime stages are distroless (Debian 13) and
chiseled (.NET), which removes the shell and package manager that most findings
attach to.

**What it does not cover.** A CVE published after the build. That is what the
weekly `schedule:` in `security.yml` is for — it rescans on a cadence rather than
only on commit. Suppressions live in [`.trivyignore.yaml`](../.trivyignore.yaml)
and each one carries a reason and an `expired_at` date; an undated suppression is
how a scanner quietly stops being a control.

---

## T4 — Dependency confusion and silent dependency drift

**How it happens.** A new transitive dependency appears — through a compromised
package, a typosquat, or a maintainer transfer. It is one line in a lockfile in a
diff nobody reads closely.

**Control.** Fully pinned lockfiles with transitive dependencies, plus
[`sbom_diff.py`](../tools/src/pipeline_tools/sbom_diff.py), which diffs this
build's CycloneDX SBOM against the last successful build on `main` and posts the
result as a sticky PR comment. Added, removed, upgraded and downgraded components
are named. `actions/dependency-review-action` independently blocks known-vulnerable
additions at `high`.

Downgrades are called out specifically: a dependency moving *backwards* is how a
patched vulnerability gets un-patched, and it is invisible in a lockfile diff.

**What it does not cover.** A malicious version of a package you already trust and
already depend on, published under the same name. The diff shows the version
change; it cannot tell you the new version is hostile.

**Demonstrated by** [`demo/vulnerable-dependency`](../../pulls).

---

## T5 — Leaked credential

**How it happens.** A key is committed, noticed, and deleted in a follow-up
commit. It is still in the history, and still valid.

**Control.** Gitleaks runs over the **full** history (`fetch-depth: 0`), not just
the diff. GitHub secret scanning and push protection are enabled on the
repository. More fundamentally: this repository has **zero configured secrets**.
Everything is green on a fresh clone with nothing set up. Production access is
designed around GitHub OIDC federation — `infra/aws/iam-github-oidc.tf` creates no
IAM user and no access key, so there is no long-lived credential to leak.

**What it does not cover.** A credential that does not match any known pattern.

**Demonstrated by** [`demo/leaked-secret`](../../pulls).

---

## T6 — Privilege escalation from a pull request

**How it happens.** Three classic routes:

- A workflow triggered by `pull_request_target` — which runs with a write token —
  checks out the pull request's code and executes it.
- Attacker-controlled text (`github.event.issue.body`, `github.head_ref`) is
  interpolated directly into a `run:` block, where a crafted branch name becomes
  shell commands on the runner.
- A job has more permissions than it needs, so a compromise of any step in it is
  a compromise of the token.

**Control.** [`workflow_audit.py`](../tools/src/pipeline_tools/workflow_audit.py)
checks all three, on every pull request, and there is a unit test asserting this
repository passes its own audit. `zizmor` and `actionlint` run alongside it as
independent implementations. Every workflow declares top-level
`permissions: contents: read`; anything more is requested per job.

On the AWS side, the OIDC trust policy uses `StringEquals` against an explicit
list of subject claims, never `repo:owner/name:*`. A wildcard subject is the
common misconfiguration that lets a workflow added by a fork's pull request assume
the role. `infra/aws/tests/security.tftest.hcl` asserts no subject contains a
wildcard, and `aws_iam_role.github_actions` carries a `lifecycle.precondition` that
fails the plan itself — so the rule holds even for someone who never runs the tests.

**What it does not cover.** A maintainer who merges hostile code.

---

## T7 — Deploying into an active incident

**How it happens.** A service is already failing. A deploy goes out on top of it.
Now there are two changes in flight and no way to tell which caused what.

**Control.** [`datadog_gate.py`](../tools/src/pipeline_tools/datadog_gate.py) queries
monitor state for the service and environment before the deploy and exits 4 if any
monitor is alerting. `Warn` and `No Data` are reported but do not block — blocking
on `No Data` means a monitor created five minutes ago blocks every deploy.

Because this repository has no Datadog account, the gate runs with
`DD_DRY_RUN=true` and logs the exact request it would send. The monitors it would
query are defined in [`infra/datadog/`](../infra/datadog/).

---

## T8 — A bad deploy with no way back

**How it happens.** A release rolls out, fails, and the evidence disappears with
the pods.

**Control.** `helm upgrade --install --atomic` rolls back automatically on
failure. [`wait-for-rollout.sh`](../scripts/wait-for-rollout.sh) calls
[`collect-diagnostics.sh`](../scripts/collect-diagnostics.sh) **before** it exits,
capturing events, describes, and the **previous** container's log — the one that
actually explains a CrashLoopBackOff — into a tarball uploaded as an artifact.
[`smoke-test.sh`](../scripts/smoke-test.sh) then asserts on response **shape**, not
just status codes, so a service returning 200 with a malformed body still fails.

**What it does not cover.** A failure that only appears under production traffic.

**Demonstrated by** [`demo/failed-deploy`](../../pulls).

---

## T9 — Insecure workload configuration reaching a cluster

**How it happens.** Resource limits get dropped during a refactor. A container
ends up running as root. An image reference loses its digest.

**Control.** [`policy/workloads.rego`](../policy/workloads.rego) — rules written
here, not imported — require CPU and memory requests, a memory limit,
`runAsNonRoot`, `allowPrivilegeEscalation: false`, dropped capabilities,
`readOnlyRootFilesystem`, no `:latest`, and both probes. conftest runs them
against the rendered manifests for **both** value files on every pull request,
alongside kube-linter and `kubeconform -strict` with vendored CRD schemas.

`values-prod.yaml` is validated identically to `values-emulator.yaml` despite
never being applied. That is the only thing keeping the production values honest.

**Demonstrated by** [`demo/policy-violation`](../../pulls).

---

## A hole this repository's own demo found

`demo/failed-deploy` was meant to show a rollback. It showed something better.

The deploy resolves a digest from the commit's tag, and falls back to the most
recently published image when the commit built none of its own. "Most recently
published" is a statement about time, not about provenance: it can be an image
whose build pushed successfully and then failed before signing, or one built from
a branch nobody reviewed.

The gate caught it — `verify-supply-chain.sh` exited 4 and the deploy stopped, which
is the fail-closed behaviour working exactly as designed. But relying on the gate
to reject a bad choice is worse than not making the bad choice. `resolve-image-digest.sh`
now takes `--verify-repo` and walks the candidates newest-first, selecting the first
that actually verifies, and exits 4 if none of the last five do.

The lesson generalises: a control that fires is evidence the control works *and*
evidence that something upstream let a bad input through.

## Residual risk, stated plainly

- **A malicious maintainer.** Every control here assumes the person merging is
  acting in good faith. CODEOWNERS and required reviews raise the cost; they do
  not remove the risk.
- **GitHub itself.** The provenance attestations, the runners and the token all
  come from one vendor. Compromise there defeats most of this.
- **The emulator is not AWS.** It proves the Terraform graph resolves and the
  Kubernetes objects are correct. It proves nothing about IAM enforcement, which
  is why `terraform test` exists with mocked providers and twelve assertions.
- **`values-prod.yaml` has never been applied.** It is schema-valid and
  policy-clean. That is not the same as known-good.
