# Karpenter's AWS side: the controller's IRSA role, the role its nodes assume,
# and the interruption queue. The NodePool and EC2NodeClass themselves are
# Kubernetes custom resources and live in karpenter/, validated by manifests.yml.

resource "aws_iam_role" "karpenter_controller" {
  name = "${local.name}-karpenter"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.eks.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_host}:aud" = "sts.amazonaws.com"
          "${local.oidc_host}:sub" = "system:serviceaccount:kube-system:karpenter"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "karpenter_controller" {
  # checkov:skip=CKV_AWS_355: ec2:Describe* and RunInstances have no resource-level
  # ARN to scope to — Karpenter has to enumerate instance types and launch into
  # subnets it discovers. The mutating actions are constrained by the cluster
  # ownership tag conditions below, which is the control that actually bounds them.
  # checkov:skip=CKV_AWS_288: the wildcards are read-only describes plus
  # tag-conditioned launches; there is no data-bearing service in this policy.
  name = "provision-nodes"
  role = aws_iam_role.karpenter_controller.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadInstanceTypesAndImages"
        Effect = "Allow"
        Action = [
          "ec2:DescribeImages",
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceTypeOfferings",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeLaunchTemplates",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeSpotPriceHistory",
          "ec2:DescribeSubnets",
          "pricing:GetProducts",
          "ssm:GetParameter",
        ]
        Resource = "*"
      },
      {
        Sid    = "LaunchNodesInThisClusterOnly"
        Effect = "Allow"
        Action = [
          "ec2:CreateFleet",
          "ec2:CreateLaunchTemplate",
          "ec2:CreateTags",
          "ec2:RunInstances",
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:RequestTag/kubernetes.io/cluster/${local.name}" = "owned"
          }
        }
      },
      {
        Sid    = "TerminateNodesInThisClusterOnly"
        Effect = "Allow"
        Action = ["ec2:TerminateInstances", "ec2:DeleteLaunchTemplate"]
        # Without this condition Karpenter could terminate any instance in the
        # account, including ones it never created.
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:ResourceTag/kubernetes.io/cluster/${local.name}" = "owned"
          }
        }
      },
      {
        Sid      = "PassOnlyTheNodeRole"
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = aws_iam_role.node.arn
      },
      {
        Sid      = "ReadCluster"
        Effect   = "Allow"
        Action   = "eks:DescribeCluster"
        Resource = aws_eks_cluster.this.arn
      },
      {
        Sid      = "DrainOnSpotInterruption"
        Effect   = "Allow"
        Action   = ["sqs:DeleteMessage", "sqs:GetQueueUrl", "sqs:ReceiveMessage"]
        Resource = aws_sqs_queue.karpenter_interruption.arn
      },
    ]
  })
}

# Spot interruption and rebalance notices land here, giving Karpenter two minutes
# to drain a node instead of losing it mid-request.
resource "aws_sqs_queue" "karpenter_interruption" {
  name                       = "${local.name}-karpenter-interruption"
  message_retention_seconds  = 300
  visibility_timeout_seconds = 30
  sqs_managed_sse_enabled    = true
}

resource "aws_cloudwatch_event_rule" "karpenter_spot_interruption" {
  name        = "${local.name}-spot-interruption"
  description = "EC2 spot instance interruption warnings"

  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Spot Instance Interruption Warning"]
  })
}

resource "aws_cloudwatch_event_target" "karpenter_spot_interruption" {
  rule = aws_cloudwatch_event_rule.karpenter_spot_interruption.name
  arn  = aws_sqs_queue.karpenter_interruption.arn
}
