variable "region" {
  description = "AWS region (London by default)"
  type        = string
  default     = "eu-west-2"
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
  default     = "aip-mortgage"
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version. Keep it in standard support; extended support costs 6x. Check with: aws eks describe-cluster-versions"
  type        = string
  default     = "1.35"
}

variable "node_instance_type" {
  description = "Worker node size. t3.medium comfortably runs both AIP microservices with 2 replicas each."
  type        = string
  default     = "t3.medium"
}

variable "node_count" {
  description = "Desired number of worker nodes"
  type        = number
  default     = 2
}
