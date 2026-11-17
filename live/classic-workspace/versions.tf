terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws        = { source = "hashicorp/aws", version = ">= 6.0, < 7.0" }
    databricks = { source = "databricks/databricks", version = "~> 1.143" }
  }

  # One state per workspace: terraform init -backend-config=envs/<workspace>.backend.hcl
  backend "s3" {}
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = var.tags
  }
}

# Both Databricks providers authenticate with the same account-admin SP (OAuth M2M) through
# DATABRICKS_CLIENT_ID / DATABRICKS_CLIENT_SECRET. Unset DATABRICKS_HOST before running.
provider "databricks" {
  alias      = "account"
  host       = "https://accounts.cloud.databricks.com"
  account_id = var.databricks_account_id
}

provider "databricks" {
  alias = "workspace"
  host  = module.workspace.workspace_url
}
