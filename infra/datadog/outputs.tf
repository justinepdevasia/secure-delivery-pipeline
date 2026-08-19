output "monitor_ids" {
  description = "Monitor ids, for reference from the deploy gate."
  value = {
    error_rate     = datadog_monitor.error_rate.id
    p99_latency    = datadog_monitor.p99_latency.id
    pod_restarts   = datadog_monitor.pod_restarts.id
    deploy_failure = datadog_monitor.deploy_failure.id
  }
}

output "slo_ids" {
  description = "SLO ids and their targets."
  value = {
    availability = datadog_service_level_objective.availability.id
    latency      = datadog_service_level_objective.latency.id
  }
}

output "monitor_tags" {
  description = "The tag set datadog_gate.py filters on."
  value       = local.tags
}
