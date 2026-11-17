variable "prefix" {
  description = "Short organisation/platform prefix used in resource names (same value as the workspaces)."
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9]{1,9}$", var.prefix))
    error_message = "prefix must be 2-10 lowercase letters or digits, starting with a letter."
  }
}

variable "databricks_account_id" {
  description = "Databricks account ID (UUID)."
  type        = string
  validation {
    condition     = can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", var.databricks_account_id))
    error_message = "databricks_account_id must be a UUID, not a placeholder."
  }
}

variable "aws_region" {
  type    = string
  default = "us-west-2"
}

variable "kms_admin_arns" {
  description = "IAM principals that administer (but cannot use) the managed-services key. Must include the Terraform deployer."
  type        = list(string)
  validation {
    condition     = length(var.kms_admin_arns) > 0
    error_message = "kms_admin_arns must not be empty, or the key becomes unmanageable."
  }
}

variable "security_alerts_sns_topic_arn" {
  description = "Existing SNS topic for key events. Its policy must allow events.amazonaws.com to publish."
  type        = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
