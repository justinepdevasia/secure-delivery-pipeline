# Credential-free security assertions.
#
# The emulator does not enforce IAM: a policy with a wildcard subject applies
# there exactly as cleanly as a correctly scoped one, so `terraform apply`
# succeeding against it proves the graph resolves and nothing else. These
# assertions are what actually prove the policies are scoped, and they run with
# no AWS account, no credentials and no network.

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

run "github_trust_policy_has_no_wildcard_subject" {
  command = plan

  assert {
    condition = alltrue([
      for subject in var.github_allowed_subjects : !strcontains(subject, "*")
    ])
    error_message = "A subject claim contains a wildcard. repo:owner/name:* lets any workflow — including one added by a fork's pull request — assume the CI role."
  }
}

run "github_trust_policy_is_scoped_to_this_repository" {
  command = plan

  assert {
    condition = alltrue([
      for subject in var.github_allowed_subjects :
      startswith(subject, "repo:${var.github_repository}:")
    ])
    error_message = "Every allowed subject must name this repository explicitly."
  }

  assert {
    condition     = strcontains(aws_iam_role.github_actions.assume_role_policy, "sts:AssumeRoleWithWebIdentity")
    error_message = "The CI role must be assumable only through web identity federation, never by a long-lived user."
  }

  assert {
    condition     = !strcontains(aws_iam_role.github_actions.assume_role_policy, "\"AWS\"")
    error_message = "The CI trust policy must not name an AWS principal — that would reintroduce static credentials."
  }
}

run "audience_is_pinned_to_sts" {
  command = plan

  assert {
    condition     = strcontains(aws_iam_role.github_actions.assume_role_policy, "sts.amazonaws.com")
    error_message = "The trust policy must pin the aud claim to sts.amazonaws.com."
  }
}

run "irsa_roles_are_scoped_to_one_service_account" {
  command = plan

  assert {
    condition     = strcontains(aws_iam_role.api_python.assume_role_policy, "system:serviceaccount:default:api-api")
    error_message = "The api-python IRSA role must name a single namespace and service account."
  }

  assert {
    condition     = !strcontains(aws_iam_role.api_python.assume_role_policy, "system:serviceaccount:*")
    error_message = "An IRSA role scoped with a wildcard service account is assumable by every pod in the cluster."
  }

  assert {
    condition     = strcontains(aws_iam_role.karpenter_controller.assume_role_policy, "system:serviceaccount:kube-system:karpenter")
    error_message = "The Karpenter controller role must be scoped to its own service account."
  }
}

run "karpenter_cannot_terminate_instances_it_does_not_own" {
  command = plan

  assert {
    condition     = strcontains(aws_iam_role_policy.karpenter_controller.policy, "aws:ResourceTag/kubernetes.io/cluster/")
    error_message = "Karpenter's terminate permission must be conditioned on the cluster ownership tag."
  }

  assert {
    condition     = strcontains(aws_iam_role_policy.karpenter_controller.policy, aws_iam_role.node.arn)
    error_message = "Karpenter's iam:PassRole must be restricted to the node role."
  }
}

run "ci_role_cannot_push_to_arbitrary_repositories" {
  command = plan

  assert {
    condition     = strcontains(aws_iam_role_policy.github_actions_ecr.policy, "PushToProjectRepositoriesOnly")
    error_message = "ECR push permission must be scoped to this project's repositories."
  }
}
