# Security policy

This is a portfolio repository. It runs no production service and holds no user
data. Reports are still welcome — the code here is meant to demonstrate that
these controls work, and a control that does not work is worth knowing about.

## Reporting a vulnerability

Open a [private security advisory](https://github.com/justinepdevasia/secure-delivery-pipeline/security/advisories/new).
Please do not open a public issue for anything exploitable.

Expect an acknowledgement within a few days. There is no bounty.

## What is in scope

- A way to get an unsigned, unverified or tampered image past the deploy gate
  in `scripts/verify-supply-chain.sh`
- A workflow that can be made to run attacker-controlled code, or to leak
  `GITHUB_TOKEN`, from a pull request
- A way to defeat `scripts/audit-action-pins.sh` or `pipeline_tools.workflow_audit`
  — the two checks this repository enforces on itself
- A committed credential, or a path by which one could be committed unnoticed

## What is out of scope

- Findings in the emulated AWS layer. The emulator does not enforce IAM, and the
  repository does not claim it does — see the "what is real and what is emulated"
  section of the README.
- `charts/api/values-prod.yaml` and `infra/datadog/`. These are never applied to
  anything; they are validated as configuration, and the account IDs, ARNs and
  certificate identifiers in them are placeholders.
- The demo pull requests under `demo/*`. Those introduce known problems on
  purpose, so the pipeline can be seen catching them.

## How this repository is defended

| Control | Where |
| --- | --- |
| Actions pinned to commit SHAs, enforced in CI | `scripts/audit-action-pins.sh` |
| Workflow permissions and injection checks | `pipeline_tools.workflow_audit` |
| Image signing and attestation, verified before deploy | `scripts/verify-supply-chain.sh` |
| Vulnerability scanning before an image reaches a registry | `.github/workflows/reusable-build-attest.yml` |
| Secret scanning over full history | Gitleaks, in `.github/workflows/security.yml` |
| Static analysis | CodeQL, zizmor, actionlint, Checkov, Trivy |
| Dependency review on every pull request | `actions/dependency-review-action` |

Every one of these blocks a merge. None of them is advisory.
