#!/usr/bin/env bash
# Removes everything from AWS so it stops using credits.
# Namespaces go first: each aip-webapp LoadBalancer Service owns an AWS load balancer that
# Terraform doesn't know about, and it would otherwise block the VPC from being deleted.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REGION="${AWS_REGION:-eu-west-2}"
CLUSTER="${CLUSTER_NAME:-aip-mortgage}"

if aws eks describe-cluster --region "$REGION" --name "$CLUSTER" >/dev/null 2>&1; then
  aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER" >/dev/null
  for env in sit-01 sit-02; do
    echo "==> Deleting ${env} namespaces (and their load balancers)"
    kubectl delete namespace "${env}-dip" "${env}-api" "${env}-data" --ignore-not-found --wait=true
  done
fi

echo "==> Destroying cluster, VPC and ECR repositories"
terraform -chdir="${ROOT}/infra/terraform" destroy -auto-approve \
  -var "region=${REGION}" -var "cluster_name=${CLUSTER}"
