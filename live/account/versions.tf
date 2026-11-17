terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws        = { source = "hashicorp/aws", version = ">= 6.0, < 7.0" }
    databricks = { source = "databricks/databricks", version = "~> 1.143" }
  }

  # Partial config: terraform init -backend-config=backend.hcl
  backend "s3" {}
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = var.tags
  }
}

# Auth: DATABRICKS_CLIENT_ID / DATABRICKS_CLIENT_SECRET of an account-admin service principal.
provider "databricks" {
  host       = "https://accounts.cloud.databricks.com"
  account_id = var.databricks_account_id
}
