# GitHub Actions OIDC federation. No access keys exist anywhere in this design;
# a workflow exchanges its short-lived OIDC token for a session.

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]

  # GitHub's OIDC endpoint is served from a well-known CA. AWS validates the
  # thumbprint itself for this provider; the value is required by the API.
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

locals {
  # An OIDC provider ARN is fully determined by the account and the issuer host,
  # so it is derived rather than read back from the resource. Referencing the
  # computed attribute would make every trust policy unknown until apply, and an
  # assertion cannot inspect an unknown value.
  github_oidc_provider_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/token.actions.githubusercontent.com"

  # Built with jsonencode rather than aws_iam_policy_document so the value is a
  # real configured argument: `terraform test` with a mocked provider can then
  # assert on it, which it cannot do for a data source's computed output.
  github_trust_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = local.github_oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        # StringEquals, not StringLike: an exact match cannot be widened by a
        # branch name someone chooses. `repo:owner/name:*` — the common
        # misconfiguration — lets a pull request from a fork add a workflow that
        # assumes this role, because the fork's PR ref still matches the wildcard.
        "ForAnyValue:StringEquals" = {
          "token.actions.githubusercontent.com:sub" = var.github_allowed_subjects
        }
      }
    }]
  })
}

resource "aws_iam_role" "github_actions" {
  name                 = "${local.name}-github-actions"
  assume_role_policy   = local.github_trust_policy
  max_session_duration = 3600

  tags = { Repository = var.github_repository }

  # The ARN above is derived, so the dependency is stated rather than implied.
  depends_on = [aws_iam_openid_connect_provider.github]

  lifecycle {
    # Enforced on every plan, not only in `terraform test`: a subject that names
    # another repository, or carries a wildcard, fails before anything is applied.
    precondition {
      condition = alltrue([
        for subject in var.github_allowed_subjects :
        startswith(subject, "repo:${var.github_repository}:") && !strcontains(subject, "*")
      ])
      error_message = "Every github_allowed_subjects entry must start with repo:${var.github_repository}: and contain no wildcard."
    }
  }
}

resource "aws_iam_role_policy" "github_actions_ecr" {
  name = "push-images"
  role = aws_iam_role.github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "AuthenticateToECR"
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        Sid    = "PushToProjectRepositoriesOnly"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:BatchGetImage",
          "ecr:CompleteLayerUpload",
          "ecr:DescribeImages",
          "ecr:GetDownloadUrlForLayer",
          "ecr:InitiateLayerUpload",
          "ecr:PutImage",
          "ecr:UploadLayerPart",
        ]
        Resource = [for repo in aws_ecr_repository.this : repo.arn]
      },
    ]
  })
}

resource "aws_iam_role_policy" "github_actions_eks" {
  name = "describe-cluster"
  role = aws_iam_role.github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      # Enough to build a kubeconfig, nothing more. Kubernetes RBAC decides what
      # the resulting identity can actually do inside the cluster.
      Effect   = "Allow"
      Action   = ["eks:DescribeCluster"]
      Resource = aws_eks_cluster.this.arn
    }]
  })
}
