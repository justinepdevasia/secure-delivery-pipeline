# Policies this repository wrote, enforced by conftest against every rendered
# manifest on every pull request. They are deliberately the boring ones — the
# rules that get skipped under deadline pressure and cause the 3am page.
package main

import rego.v1

workload_kinds := {"Deployment", "StatefulSet", "DaemonSet", "Job", "CronJob"}

is_workload if input.kind in workload_kinds

pod_spec := input.spec.template.spec if is_workload

containers contains c if {
	is_workload
	some c in object.get(pod_spec, "containers", [])
}

containers contains c if {
	is_workload
	some c in object.get(pod_spec, "initContainers", [])
}

name := object.get(input, ["metadata", "name"], "<unnamed>")

# --- resources ------------------------------------------------------------
# An unbounded container is a noisy-neighbour incident waiting for a bad deploy.

deny contains msg if {
	some c in containers
	not c.resources.requests.cpu
	msg := sprintf("%s/%s: container %q must declare a CPU request", [input.kind, name, c.name])
}

deny contains msg if {
	some c in containers
	not c.resources.requests.memory
	msg := sprintf("%s/%s: container %q must declare a memory request", [input.kind, name, c.name])
}

deny contains msg if {
	some c in containers
	not c.resources.limits.memory
	msg := sprintf("%s/%s: container %q must declare a memory limit", [input.kind, name, c.name])
}

# --- identity -------------------------------------------------------------

deny contains msg if {
	some c in containers
	not runs_as_non_root(c)
	msg := sprintf("%s/%s: container %q must set runAsNonRoot", [input.kind, name, c.name])
}

runs_as_non_root(c) if c.securityContext.runAsNonRoot == true

runs_as_non_root(_) if pod_spec.securityContext.runAsNonRoot == true

deny contains msg if {
	some c in containers
	c.securityContext.allowPrivilegeEscalation != false
	msg := sprintf(
		"%s/%s: container %q must set allowPrivilegeEscalation: false",
		[input.kind, name, c.name],
	)
}

deny contains msg if {
	some c in containers
	not drops_all_capabilities(c)
	msg := sprintf("%s/%s: container %q must drop ALL capabilities", [input.kind, name, c.name])
}

drops_all_capabilities(c) if "ALL" in object.get(c, ["securityContext", "capabilities", "drop"], [])

deny contains msg if {
	some c in containers
	c.securityContext.readOnlyRootFilesystem != true
	msg := sprintf(
		"%s/%s: container %q must set readOnlyRootFilesystem: true",
		[input.kind, name, c.name],
	)
}

# --- images ---------------------------------------------------------------
# A floating tag makes the running image unknowable after the fact.

deny contains msg if {
	some c in containers
	endswith(c.image, ":latest")
	msg := sprintf("%s/%s: container %q must not use the :latest tag", [input.kind, name, c.name])
}

deny contains msg if {
	some c in containers
	not contains(c.image, "@sha256:")
	not endswith(c.image, ":latest")
	not contains(c.image, ":")
	msg := sprintf("%s/%s: container %q image %q has no tag or digest", [
		input.kind, name, c.name,
		c.image,
	])
}

# --- probes ---------------------------------------------------------------
# Without a readiness probe, a rollout reports success the moment the container
# starts, and traffic lands on a process that is not ready for it.

deny contains msg if {
	input.kind in {"Deployment", "StatefulSet", "DaemonSet"}
	some c in object.get(pod_spec, "containers", [])
	not c.readinessProbe
	msg := sprintf("%s/%s: container %q must declare a readinessProbe", [input.kind, name, c.name])
}

deny contains msg if {
	input.kind in {"Deployment", "StatefulSet", "DaemonSet"}
	some c in object.get(pod_spec, "containers", [])
	not c.livenessProbe
	msg := sprintf("%s/%s: container %q must declare a livenessProbe", [input.kind, name, c.name])
}

# --- warnings -------------------------------------------------------------
# Advisory: a single replica is a planned outage during any node rotation.

warn contains msg if {
	input.kind == "Deployment"
	object.get(input, ["spec", "replicas"], 1) < 2
	msg := sprintf("Deployment/%s: a single replica has no availability during a node drain", [name])
}
