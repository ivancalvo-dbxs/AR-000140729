terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0, < 7.0"
    }
    databricks = {
      source                = "databricks/databricks"
      version               = "~> 1.143"
      configuration_aliases = [databricks.account, databricks.workspace]
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.6"
    }
    time = {
      source  = "hashicorp/time"
      version = ">= 0.11"
    }
  }
}
