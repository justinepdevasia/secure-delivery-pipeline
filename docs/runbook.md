# Runbook

Referenced from the Datadog monitors in `infra/datadog/`. Short on purpose: a
runbook nobody can read at 3am is not a runbook.

## error-rate

5xx ratio above threshold.

1. `helm history api -n default` — did something deploy in the last hour?
2. If yes: `helm rollback api -n default --wait`. Diagnose afterwards.
3. If no: check the pod logs for the failing dependency, and whether
   `/readyz` reports `secrets_source=defaults` — that means the configuration
   lookup is failing and the service is running on fallbacks.

## latency

p99 above objective.

1. Check pod CPU against the limit. The CPU limit is 4x the request; sustained
   throttling means the request is wrong, not the limit.
2. Check whether the HPA is at `maxReplicas`.
3. Check the Secrets Manager code path — `config.py` bounds it at 2s connect and
   3s read, so a slow endpoint shows up as latency rather than as a hang.

## crashloop

Containers restarting.

1. `kubectl logs <pod> --previous` — the current log is the one that has not
   failed yet.
2. OOM kill? The memory limit is only 2x the request; memory is not compressible.
3. Readiness probe never passing? Confirm the pod can reach its configuration
   source.

## failed-deploy

Desired replicas exceed available for longer than a rollout should take.

1. `kubectl get events --sort-by=.lastTimestamp` — `ErrImagePull` is the usual
   answer, and usually means the digest does not exist in the registry the
   cluster pulls from.
2. `helm rollback api -n default`.
3. The deploy workflow uploads a diagnostics bundle as an artifact on every
   failure; start there rather than reconstructing state by hand.
