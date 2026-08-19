# What and why

<!-- One paragraph. What changes, and what problem it solves. -->

## Supply chain

<!-- Delete the lines that do not apply. Leaving an unticked box is a legitimate
     answer — it tells the reviewer where to look. -->

- [ ] Any new `uses:` is pinned to a full 40-character commit SHA with the version in a trailing comment
- [ ] Any new image is pinned by digest, not by tag
- [ ] New or changed dependencies are in a committed lockfile
- [ ] `.trivyignore.yaml` entries added here carry a reason and an expiry date
- [ ] No secret, token or credential is committed — including in a test fixture

## Blast radius

- [ ] New workflow jobs declare an explicit `permissions:` block
- [ ] IAM or RBAC changes are scoped to a specific resource, not `*`
- [ ] Changes to `charts/api/values-prod.yaml` were checked against `values-emulator.yaml` for drift

## Evidence

<!-- Link the green run. "It should work" is not evidence; the CI run is. -->

- Run:
- What was verified end to end:

## Rollback

<!-- How is this undone if it misbehaves in production? "Revert the commit" is a
     fine answer when it is actually true. -->
