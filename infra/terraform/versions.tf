terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.95"
    }
  }

  # State is local by default (fine for a personal demo).
  # For team use, switch to an S3 backend with a lock table.
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "aip-mortgage"
      ManagedBy = "terraform"
    }
  }
}
