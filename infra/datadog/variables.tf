# Credentials default to empty strings so `terraform validate` runs with no
# secrets configured anywhere. This configuration is never planned or applied.

variable "api_key" {
  description = "Datadog API key. Empty by default — validation needs no credentials."
  type        = string
  default     = ""
  sensitive   = true
}

variable "app_key" {
  description = "Datadog application key. Empty by default."
  type        = string
  default     = ""
  sensitive   = true
}

variable "api_url" {
  description = "Datadog API endpoint."
  type        = string
  default     = "https://api.datadoghq.com/"
}

variable "service" {
  description = "Service tag these monitors watch."
  type        = string
  default     = "api-python"
}

variable "environment" {
  description = "Environment tag these monitors watch."
  type        = string
  default     = "production"
}

variable "notify" {
  description = "Notification handles appended to every monitor message."
  type        = string
  default     = "@slack-delivery-alerts"
}

variable "error_rate_critical" {
  description = "5xx ratio that pages."
  type        = number
  default     = 0.02
}

variable "error_rate_warning" {
  description = "5xx ratio that warns."
  type        = number
  default     = 0.01
}

variable "p99_critical_seconds" {
  description = "p99 latency that pages, in seconds."
  type        = number
  default     = 1.5
}

variable "p99_warning_seconds" {
  description = "p99 latency that warns, in seconds."
  type        = number
  default     = 0.75
}

variable "restart_critical" {
  description = "Container restarts in ten minutes that page."
  type        = number
  default     = 3
}
