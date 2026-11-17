# Account-wide controls shared by every workspace.

# The reserved default policy applies to any workspace without its own: deny all egress.
import {
  to = databricks_account_network_policy.default
  id = "default-policy"
}

resource "databricks_account_network_policy" "default" {
  account_id        = var.databricks_account_id
  network_policy_id = "default-policy"

  egress = {
    network_access = {
      restriction_mode   = "RESTRICTED_ACCESS"
      policy_enforcement = { enforcement_mode = "ENFORCED" }
    }
  }
}

# No DBFS root, mounts or Hive metastore on new workspaces.
resource "databricks_disable_legacy_features_setting" "this" {
  disable_legacy_features {
    value = true
  }
}

# ---------------------------------------------------------------------------
# Managed-services CMK for control-plane data and default storage.
# Serverless workspaces only use the MANAGED_SERVICES use case.
# ---------------------------------------------------------------------------

resource "aws_kms_key" "managed_services" {
  description         = "Databricks managed services (control plane and default storage)"
  enable_key_rotation = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "KeyAdministration"
        Effect    = "Allow"
        Principal = { AWS = var.kms_admin_arns }
        Action = [
          "kms:Create*", "kms:Describe*", "kms:Enable*", "kms:List*", "kms:Put*", "kms:Update*",
          "kms:Revoke*", "kms:Disable*", "kms:Get*", "kms:Delete*", "kms:TagResource",
          "kms:UntagResource", "kms:ScheduleKeyDeletion", "kms:CancelKeyDeletion", "kms:RotateKeyOnDemand",
        ]
        Resource = "*"
      },
      {
        # Least Databricks access: exactly the documented managed-services statement.
        Sid       = "DatabricksManagedServices"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::414351767826:root" }
        Action    = ["kms:Encrypt", "kms:Decrypt"]
        Resource  = "*"
        Condition = { StringEquals = { "aws:PrincipalTag/DatabricksAccountId" = [var.databricks_account_id] } }
      },
    ]
  })
}

resource "aws_kms_alias" "managed_services" {
  name          = "alias/${var.prefix}-databricks-managed-services"
  target_key_id = aws_kms_key.managed_services.key_id
}

resource "databricks_mws_customer_managed_keys" "managed_services" {
  account_id = var.databricks_account_id
  use_cases  = ["MANAGED_SERVICES"]

  aws_key_info {
    key_arn   = aws_kms_key.managed_services.arn
    key_alias = aws_kms_alias.managed_services.name
  }
}

# Key events monitored: anything that could cut Databricks off or widen access to the key.
# Relies on the account's CloudTrail management events (for example an organization trail).
resource "aws_cloudwatch_event_rule" "kms_key_changes" {
  name        = "${var.prefix}-databricks-kms-key-changes"
  description = "Disable, deletion, policy and grant changes on Databricks KMS keys"

  event_pattern = jsonencode({
    source      = ["aws.kms"]
    detail-type = ["AWS API Call via CloudTrail"]
    detail = {
      eventSource = ["kms.amazonaws.com"]
      eventName   = ["DisableKey", "ScheduleKeyDeletion", "PutKeyPolicy", "CreateGrant", "RevokeGrant", "DeleteAlias", "UpdateAlias"]
    }
  })
}

resource "aws_cloudwatch_event_target" "kms_key_changes" {
  rule = aws_cloudwatch_event_rule.kms_key_changes.name
  arn  = var.security_alerts_sns_topic_arn
}
