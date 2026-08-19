# Assertions about the cluster and registry posture. Same reasoning as
# security.tftest.hcl: an emulated apply cannot prove any of this.

mock_provider "aws" {
  # A mocked data source returns nothing by default, so the values the
  # configuration actually indexes into have to be supplied here.
  mock_data "aws_availability_zones" {
    defaults = {
      names = ["us-east-1a", "us-east-1b", "us-east-1c"]
    }
  }

  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "000000000000"
    }
  }

  mock_resource "aws_eks_cluster" {
    defaults = {
      identity = [{
        oidc = [{
          issuer = "https://oidc.eks.us-east-1.amazonaws.com/id/EXAMPLED539D4633E53DE1B716D3041E"
        }]
      }]
    }
  }
}

mock_provider "tls" {
  mock_data "tls_certificate" {
    defaults = {
      certificates = [{
        sha1_fingerprint = "9e99a48a9960b14926bb7f3b02e22da2b0ab7280"
      }]
    }
  }
}

run "cluster_api_is_not_exposed_to_the_internet" {
  command = plan

  assert {
    condition     = aws_eks_cluster.this.vpc_config[0].endpoint_public_access == false
    error_message = "The EKS API server must not be publicly reachable."
  }

  assert {
    condition     = aws_eks_cluster.this.vpc_config[0].endpoint_private_access == true
    error_message = "Private endpoint access must be enabled or nothing can reach the API server."
  }
}

run "cluster_secrets_are_envelope_encrypted_and_audited" {
  command = plan

  assert {
    condition     = length(aws_eks_cluster.this.encryption_config) == 1
    error_message = "Kubernetes secrets must be envelope encrypted with a customer-managed key."
  }

  assert {
    condition     = contains(aws_eks_cluster.this.enabled_cluster_log_types, "audit")
    error_message = "Audit logging must be on; it cannot be enabled retroactively after an incident."
  }

  assert {
    condition     = aws_kms_key.eks.enable_key_rotation == true
    error_message = "The cluster KMS key must have rotation enabled."
  }
}

run "cluster_creator_does_not_get_implicit_admin" {
  command = plan

  assert {
    condition     = aws_eks_cluster.this.access_config[0].bootstrap_cluster_creator_admin_permissions == false
    error_message = "Whoever ran terraform apply must not silently become cluster admin."
  }
}

run "nodes_run_in_private_subnets_only" {
  command = plan

  assert {
    condition = alltrue([
      for subnet in aws_subnet.private : subnet.map_public_ip_on_launch == false
    ])
    error_message = "Private subnets must not assign public IPs."
  }

  assert {
    condition     = length(aws_eks_node_group.system.subnet_ids) == var.availability_zone_count
    error_message = "The node group must span every configured availability zone."
  }
}

run "image_tags_are_immutable_and_scanned" {
  command = plan

  assert {
    condition = alltrue([
      for repo in aws_ecr_repository.this : repo.image_tag_mutability == "IMMUTABLE"
    ])
    error_message = "Mutable tags let a reviewed tag be repointed at a different image."
  }

  assert {
    condition = alltrue([
      for repo in aws_ecr_repository.this :
      repo.image_scanning_configuration[0].scan_on_push == true
    ])
    error_message = "Scan-on-push must be enabled for every repository."
  }
}

run "a_two_az_cluster_is_the_minimum" {
  command = plan

  variables {
    availability_zone_count = 2
  }

  assert {
    condition     = length(aws_subnet.private) >= 2
    error_message = "At least two private subnets are required."
  }

  assert {
    condition     = length(aws_nat_gateway.this) == length(aws_subnet.public)
    error_message = "One NAT gateway per AZ: a shared NAT makes every private subnet depend on a single zone."
  }
}
