# Every variable has a default, so `terraform validate` and `terraform test` run
# with no tfvars and no credentials.

variable "region" {
  description = "AWS region."
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name, used in tags and resource names."
  type        = string
  default     = "production"
}

variable "project" {
  description = "Name prefix for every resource."
  type        = string
  default     = "secure-delivery-pipeline"
}

variable "github_repository" {
  description = "owner/name of the repository allowed to assume the CI role."
  type        = string
  default     = "justinepdevasia/secure-delivery-pipeline"

  validation {
    condition     = can(regex("^[^/]+/[^/*]+$", var.github_repository))
    error_message = "github_repository must be owner/name with no wildcard."
  }
}

variable "github_allowed_subjects" {
  description = <<-EOT
    Exact OIDC subject claims permitted to assume the CI role.

    A bare `repo:owner/name:*` is the common misconfiguration: it lets any
    workflow in the repository assume the role, including one added by a pull
    request from a fork. Every entry here names a specific environment, branch or
    tag, and infra-test.yml asserts that none of them contains a wildcard.
  EOT
  type        = list(string)
  default = [
    "repo:justinepdevasia/secure-delivery-pipeline:environment:production",
    "repo:justinepdevasia/secure-delivery-pipeline:ref:refs/heads/main",
  ]
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.42.0.0/16"
}

variable "availability_zone_count" {
  description = "Number of AZs to spread subnets across."
  type        = number
  default     = 3

  validation {
    condition     = var.availability_zone_count >= 2
    error_message = "At least two availability zones are required for a highly available cluster."
  }
}

variable "kubernetes_version" {
  description = "EKS control plane version."
  type        = string
  default     = "1.34"
}

variable "node_group" {
  description = "Managed node group sizing. Karpenter provisions everything beyond this."
  type = object({
    instance_types = list(string)
    desired_size   = number
    min_size       = number
    max_size       = number
  })
  default = {
    instance_types = ["t3.medium"]
    desired_size   = 2
    min_size       = 2
    max_size       = 4
  }
}

variable "ecr_repositories" {
  description = "Image repositories to create."
  type        = list(string)
  default     = ["api-python", "api-dotnet"]
}

variable "log_retention_days" {
  description = <<-EOT
    CloudWatch log retention. A year, because the questions that need audit logs
    ("when did this identity first appear?") are usually asked months later.
  EOT
  type        = number
  default     = 365
}

variable "emulator" {
  description = <<-EOT
    Emulator overrides, kept in one object so they cannot leak into production by
    accident: `enabled = false` (the default) means no endpoint override is
    configured at all, whatever else is set here.
  EOT
  type = object({
    enabled      = bool
    endpoint_url = string
    access_key   = string
    secret_key   = string
  })
  default = {
    enabled      = false
    endpoint_url = ""
    access_key   = null
    secret_key   = null
  }
}
