terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # Pinned: a provider is as much of a supply chain dependency as an action.
      version = "~> 6.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  region = var.region

  # The emulated apply sets these through emulator.tfvars. They are empty in the
  # production configuration, so nothing here can accidentally point at the
  # emulator when it matters.
  access_key                  = var.emulator.access_key
  secret_key                  = var.emulator.secret_key
  skip_credentials_validation = var.emulator.enabled
  skip_metadata_api_check     = var.emulator.enabled
  skip_requesting_account_id  = var.emulator.enabled

  dynamic "endpoints" {
    for_each = var.emulator.enabled ? [var.emulator.endpoint_url] : []
    content {
      ec2            = endpoints.value
      ecr            = endpoints.value
      eks            = endpoints.value
      iam            = endpoints.value
      secretsmanager = endpoints.value
      sts            = endpoints.value
      kms            = endpoints.value
      logs           = endpoints.value
    }
  }

  default_tags {
    tags = {
      Project     = "secure-delivery-pipeline"
      ManagedBy   = "terraform"
      Environment = var.environment
    }
  }
}
