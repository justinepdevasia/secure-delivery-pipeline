# Contributing

The working agreement this repository was built under, kept because it is also
the fastest way to get a change merged.

## The rules that are enforced, not suggested

1. **Every third-party action is pinned to a full 40-character commit SHA**, with
   the version in a trailing comment. `scripts/audit-action-pins.sh --check` fails
   the build otherwise. Resolve a SHA with
   `gh api repos/OWNER/REPO/commits/TAG --jq .sha` — never write one from memory.
2. **Every container image is pinned by digest.** A floating tag in a repository
   about supply chain security is a self-inflicted wound.
3. **Every workflow declares an explicit `permissions:` block.**
   `workflow-audit` fails the build otherwise.
4. **No repository secrets.** Everything must be green on a fresh clone with
   nothing configured.
5. **No inline `run:` block longer than about fifteen lines.** Longer logic goes
   in `scripts/` or `tools/`, where it can be linted and unit-tested.
6. **Every script in `scripts/` and every module in `tools/` is called by a
   workflow.** Code nothing invokes is deleted, not kept.

## Local checks

The pipeline is the source of truth, but these catch most things first:

```bash
shellcheck --severity=style scripts/*.sh scripts/lib/*.sh
shfmt -d -i 2 -ci scripts/
bats scripts/tests/

cd tools && ruff check . && mypy --strict && pytest
cd services/api-python && ruff check . && mypy --strict && pytest

terraform fmt -check -recursive infra/
terraform -chdir=infra/aws test
```

## Conventions

- Conventional commits (`feat(scope):`, `fix(scope):`, `chore(deps):`).
- One logical change per pull request; the template asks for the evidence.
- Scripts take flags, never bare positional arguments, and support `--help`.
- Logging goes to stderr; stdout carries `--json` output and nothing else.
- Exit codes are shared across Bash and Python: `0` success, `1` generic failure,
  `2` usage error, `3` timeout, `4` verification failure.

## Adding a suppression

A finding you intend not to fix needs a reason and an expiry date — in
`.trivyignore.yaml`, or as an inline `#checkov:skip=ID: reason`. An undated
suppression is how a scanner quietly stops being a control.
