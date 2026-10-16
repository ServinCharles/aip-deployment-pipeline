output "region" {
  value = var.region
}

output "cluster_name" {
  value = module.eks.cluster_name
}

output "ecr_repositories" {
  description = "ECR repository URLs for each microservice"
  value       = { for name, repo in aws_ecr_repository.service : name => repo.repository_url }
}

output "configure_kubectl" {
  value = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}
