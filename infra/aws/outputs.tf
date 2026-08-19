output "cluster_name" {
  description = "EKS cluster name."
  value       = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  description = "EKS API server endpoint."
  value       = aws_eks_cluster.this.endpoint
}

output "oidc_provider_arn" {
  description = "Cluster OIDC provider ARN, used by every IRSA role."
  value       = aws_iam_openid_connect_provider.eks.arn
}

output "github_actions_role_arn" {
  description = "Role GitHub Actions assumes through OIDC."
  value       = aws_iam_role.github_actions.arn
}

output "ecr_repository_urls" {
  description = "Image repository URLs."
  value       = { for name, repo in aws_ecr_repository.this : name => repo.repository_url }
}

output "api_python_role_arn" {
  description = "IRSA role for the api-python service account."
  value       = aws_iam_role.api_python.arn
}

output "secret_arn" {
  description = "Secrets Manager secret the service reads its configuration from."
  value       = aws_secretsmanager_secret.api_python.arn
}
