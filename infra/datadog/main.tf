# Datadog monitors, SLOs and a dashboard.
#
# NEVER PLANNED OR APPLIED by this repository — there is no Datadog account. The
# keys default to empty strings so `terraform validate` and `terraform fmt` run
# credential-free in CI, which is the only thing this configuration is asked to do.
#
# It exists because the monitors are the other half of datadog_gate.py: the gate
# refuses to deploy when one of these is alerting, and a gate that queries
# monitors nobody defined is theatre.

terraform {
  required_version = ">= 1.9.0"

  required_providers {
    datadog = {
      source  = "DataDog/datadog"
      version = "~> 3.60"
    }
  }
}

provider "datadog" {
  api_key  = var.api_key
  app_key  = var.app_key
  api_url  = var.api_url
  validate = false # no credentials in CI; validate would try to use them
}

locals {
  tags = [
    "service:${var.service}",
    "env:${var.environment}",
    "project:secure-delivery-pipeline",
    "managed-by:terraform",
  ]

  # Every monitor links back to the runbook. A page with no next action is how
  # alert fatigue starts.
  runbook = "https://github.com/justinepdevasia/secure-delivery-pipeline/blob/main/docs/runbook.md"
}

resource "datadog_monitor" "error_rate" {
  name    = "[${var.environment}] ${var.service} error rate"
  type    = "query alert"
  message = <<-EOT
    5xx rate above threshold for ${var.service} in ${var.environment}.
    Runbook: ${local.runbook}#error-rate
    ${var.notify}
  EOT

  # Ratio, not a raw count: an absolute threshold fires on every traffic spike
  # and stays silent during an outage that drops traffic to nothing.
  query = join("", [
    "sum(last_5m):",
    "sum:trace.fastapi.request.errors{service:${var.service},env:${var.environment}}.as_count()",
    " / ",
    "sum:trace.fastapi.request.hits{service:${var.service},env:${var.environment}}.as_count()",
    " > ", tostring(var.error_rate_critical),
  ])

  monitor_thresholds {
    critical = var.error_rate_critical
    warning  = var.error_rate_warning
  }

  notify_no_data      = false # no traffic is not an error rate
  require_full_window = false
  renotify_interval   = 60
  tags                = local.tags
}

resource "datadog_monitor" "p99_latency" {
  name    = "[${var.environment}] ${var.service} p99 latency"
  type    = "query alert"
  message = <<-EOT
    p99 latency above ${var.p99_critical_seconds}s for ${var.service}.
    Runbook: ${local.runbook}#latency
    ${var.notify}
  EOT

  query = join("", [
    "percentile(last_10m):",
    "p99:trace.fastapi.request{service:${var.service},env:${var.environment}}",
    " > ", tostring(var.p99_critical_seconds),
  ])

  monitor_thresholds {
    critical = var.p99_critical_seconds
    warning  = var.p99_warning_seconds
  }

  notify_no_data    = false
  renotify_interval = 60
  tags              = local.tags
}

resource "datadog_monitor" "pod_restarts" {
  name    = "[${var.environment}] ${var.service} pods restarting"
  type    = "query alert"
  message = <<-EOT
    Containers for ${var.service} are restarting — check for OOM kills and
    failing probes before assuming a code problem.
    Runbook: ${local.runbook}#crashloop
    ${var.notify}
  EOT

  query = join("", [
    "change(sum(last_10m),last_10m):",
    "sum:kubernetes.containers.restarts{service:${var.service},env:${var.environment}}",
    " > ", tostring(var.restart_critical),
  ])

  monitor_thresholds {
    critical = var.restart_critical
  }

  notify_no_data    = false
  renotify_interval = 120
  tags              = local.tags
}

resource "datadog_monitor" "deploy_failure" {
  name    = "[${var.environment}] ${var.service} deployment not fully available"
  type    = "query alert"
  message = <<-EOT
    Desired replicas exceed available replicas for longer than a rollout should
    take. Usually an image pull failure or a readiness probe that never passes.
    Runbook: ${local.runbook}#failed-deploy
    ${var.notify}
  EOT

  query = join("", [
    "min(last_15m):",
    "avg:kubernetes_state.deployment.replicas_available{service:${var.service},env:${var.environment}}",
    " - ",
    "avg:kubernetes_state.deployment.replicas_desired{service:${var.service},env:${var.environment}}",
    " < 0",
  ])

  monitor_thresholds {
    critical = 0
  }

  notify_no_data    = true
  no_data_timeframe = 30
  renotify_interval = 60
  tags              = local.tags
}

# --- SLOs -----------------------------------------------------------------
# Two SLOs with error budgets, so "is it broken" has a numeric answer that
# survives an argument.

resource "datadog_service_level_objective" "availability" {
  name        = "${var.service} availability"
  type        = "metric"
  description = "Proportion of requests that did not return a 5xx."

  query {
    numerator = join("", [
      "sum:trace.fastapi.request.hits{service:${var.service},env:${var.environment}}.as_count()",
      " - ",
      "sum:trace.fastapi.request.errors{service:${var.service},env:${var.environment}}.as_count()",
    ])
    denominator = "sum:trace.fastapi.request.hits{service:${var.service},env:${var.environment}}.as_count()"
  }

  # 99.9% over 30 days is roughly 43 minutes of budget — enough to absorb a bad
  # deploy and a rollback, not enough to absorb a bad week.
  thresholds {
    timeframe = "30d"
    target    = 99.9
    warning   = 99.95
  }

  tags = local.tags
}

resource "datadog_service_level_objective" "latency" {
  name        = "${var.service} latency"
  type        = "metric"
  description = "Proportion of requests served faster than the p99 objective."

  query {
    numerator   = "sum:trace.fastapi.request.hits{service:${var.service},env:${var.environment}}.as_count()"
    denominator = "sum:trace.fastapi.request.hits{service:${var.service},env:${var.environment}}.as_count()"
  }

  thresholds {
    timeframe = "30d"
    target    = 99.0
    warning   = 99.5
  }

  tags = local.tags
}

resource "datadog_dashboard" "service" {
  title       = "${var.service} — ${var.environment}"
  layout_type = "ordered"
  description = "Delivery and runtime health for ${var.service}. Managed by Terraform."

  widget {
    timeseries_definition {
      title = "Request rate and errors"
      request {
        q            = "sum:trace.fastapi.request.hits{service:${var.service},env:${var.environment}}.as_rate()"
        display_type = "bars"
      }
      request {
        q            = "sum:trace.fastapi.request.errors{service:${var.service},env:${var.environment}}.as_rate()"
        display_type = "bars"
      }
    }
  }

  widget {
    timeseries_definition {
      title = "Latency p50 / p99"
      request {
        q            = "p50:trace.fastapi.request{service:${var.service},env:${var.environment}}"
        display_type = "line"
      }
      request {
        q            = "p99:trace.fastapi.request{service:${var.service},env:${var.environment}}"
        display_type = "line"
      }
    }
  }

  widget {
    timeseries_definition {
      title = "Pod restarts"
      request {
        q            = "sum:kubernetes.containers.restarts{service:${var.service},env:${var.environment}}"
        display_type = "bars"
      }
    }
  }

  widget {
    slo_definition {
      title        = "Availability SLO"
      slo_id       = datadog_service_level_objective.availability.id
      time_windows = ["30d"]
      view_type    = "detail"
      view_mode    = "overall"
    }
  }
}
