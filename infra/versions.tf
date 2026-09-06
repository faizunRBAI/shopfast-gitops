terraform {
  required_version = ">= 1.6.0"

  # Backend intentionally EMPTY — bucket/key/region are supplied at init time via
  # -backend-config flags from the platform (TF_STATE_BUCKET / PROJECT_NAME secrets).
  backend "s3" {}

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = var.project_name
      ManagedBy = "udap"
      Stack     = "shopfast-gitops"
    }
  }
}
