# Classic workspace in a customer-managed VPC, plus the shared security baseline.

data "aws_caller_identity" "current" {}

module "names" {
  source = "../naming"

  prefix      = var.prefix
  zone        = var.zone
  function    = var.function
  environment = var.environment
  aws_region  = var.aws_region
}

locals {
  databricks_aws_account_id = "414351767826" # Databricks control plane (commercial)

  # Region data from the Databricks docs, as packaged by the Security Reference Architecture.
  region = {
    "us-west-2" = {
      name                   = "oregon"
      rest_endpoint_service  = "com.amazonaws.vpce.us-west-2.vpce-svc-0129f463fcfbc46c5"
      relay_endpoint_service = "com.amazonaws.vpce.us-west-2.vpce-svc-0158114c0c730c3bb"
      read_buckets           = ["databricks-prod-artifacts-us-west-2", "databricks-update-oregon", "system-tables-prod-us-west-2-uc-metastore-bucket"]
      log_bucket             = "databricks-prod-storage-oregon"
    }
    "us-east-2" = {
      name                   = "ohio"
      rest_endpoint_service  = "com.amazonaws.vpce.us-east-2.vpce-svc-041dc2b4d7796b8d3"
      relay_endpoint_service = "com.amazonaws.vpce.us-east-2.vpce-svc-090a8fab0d73e39a6"
      read_buckets           = ["databricks-prod-artifacts-us-east-2", "system-tables-prod-us-east-2-uc-metastore-bucket"]
      log_bucket             = "databricks-prod-storage-ohio"
    }
  }[var.aws_region]

  cross_account_role_name = "${module.names.workspace_name}-cross-account"
}

resource "random_string" "root_bucket_suffix" {
  length  = 6
  special = false
  upper   = false
}

# ---------------------------------------------------------------------------
# Cross-account role, restricted to this VPC, security group and Databricks AMIs.
# ---------------------------------------------------------------------------

data "databricks_aws_assume_role_policy" "this" {
  provider    = databricks.account
  external_id = var.databricks_account_id
}

data "databricks_aws_crossaccount_policy" "this" {
  provider          = databricks.account
  policy_type       = "restricted"
  aws_account_id    = data.aws_caller_identity.current.account_id
  region            = var.aws_region
  vpc_id            = aws_vpc.this.id
  security_group_id = aws_security_group.workspace.id
}

resource "aws_iam_role" "cross_account" {
  name               = local.cross_account_role_name
  assume_role_policy = data.databricks_aws_assume_role_policy.this.json
}

resource "aws_iam_role_policy" "cross_account" {
  name   = "databricks-cross-account"
  role   = aws_iam_role.cross_account.id
  policy = data.databricks_aws_crossaccount_policy.this.json
}

# IAM is eventually consistent; credential validation fails without the wait.
resource "time_sleep" "cross_account" {
  create_duration = "30s"
  depends_on      = [aws_iam_role_policy.cross_account]
}

# ---------------------------------------------------------------------------
# Workspace storage CMK: root bucket (DBFS) and cluster EBS volumes.
# ---------------------------------------------------------------------------

resource "aws_kms_key" "workspace_storage" {
  description         = "${module.names.workspace_name} workspace storage (root bucket and EBS)"
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
        Sid       = "DatabricksRootStorage"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${local.databricks_aws_account_id}:root" }
        Action    = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:DescribeKey"]
        Resource  = "*"
        Condition = { StringEquals = { "aws:PrincipalTag/DatabricksAccountId" = [var.databricks_account_id] } }
      },
      {
        Sid       = "DatabricksEbsThroughEc2Only"
        Effect    = "Allow"
        Principal = { AWS = aws_iam_role.cross_account.arn }
        Action    = ["kms:Decrypt", "kms:GenerateDataKey*", "kms:CreateGrant", "kms:DescribeKey"]
        Resource  = "*"
        Condition = { "ForAnyValue:StringLike" = { "kms:ViaService" = "ec2.*.amazonaws.com" } }
      },
    ]
  })
}

resource "aws_kms_alias" "workspace_storage" {
  name          = "${module.names.data_kms_alias}-workspace-storage"
  target_key_id = aws_kms_key.workspace_storage.key_id
}

resource "databricks_mws_customer_managed_keys" "workspace_storage" {
  provider   = databricks.account
  account_id = var.databricks_account_id
  use_cases  = ["STORAGE"]

  aws_key_info {
    key_arn   = aws_kms_key.workspace_storage.arn
    key_alias = aws_kms_alias.workspace_storage.name
  }
}

# ---------------------------------------------------------------------------
# Root bucket. Holds workspace system data only; DBFS root is disabled at account level.
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "root" {
  bucket = "${module.names.workspace_name}-root-${random_string.root_bucket_suffix.result}"
}

resource "aws_s3_bucket_ownership_controls" "root" {
  bucket = aws_s3_bucket.root.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "root" {
  bucket                  = aws_s3_bucket.root.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "root" {
  bucket = aws_s3_bucket.root.id
  rule {
    bucket_key_enabled = true
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.workspace_storage.arn
    }
  }
}

# Bootstrap policy for workspace creation; replaced by the restrictive policy below once the
# workspace ID is known (SRA pattern, hence ignore_changes).
data "databricks_aws_bucket_policy" "root" {
  provider                 = databricks.account
  bucket                   = aws_s3_bucket.root.bucket
  databricks_e2_account_id = var.databricks_account_id
}

resource "aws_s3_bucket_policy" "root_bootstrap" {
  bucket = aws_s3_bucket.root.id
  policy = data.databricks_aws_bucket_policy.root.json

  lifecycle {
    ignore_changes = [policy]
  }
  depends_on = [aws_s3_bucket_public_access_block.root]
}

resource "aws_s3_bucket_policy" "root" {
  bucket = aws_s3_bucket.root.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DatabricksRead"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${local.databricks_aws_account_id}:root" }
        Action    = ["s3:GetObject", "s3:GetObjectVersion", "s3:ListBucket", "s3:GetBucketLocation"]
        Resource  = [aws_s3_bucket.root.arn, "${aws_s3_bucket.root.arn}/*"]
        Condition = { StringEquals = { "aws:PrincipalTag/DatabricksAccountId" = var.databricks_account_id } }
      },
      {
        Sid       = "DatabricksWriteOwnWorkspacePaths"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${local.databricks_aws_account_id}:root" }
        Action    = ["s3:PutObject", "s3:DeleteObject"]
        Resource = [
          "${aws_s3_bucket.root.arn}/${local.region.name}-prod/0_databricks_dev",
          "${aws_s3_bucket.root.arn}/ephemeral/${local.region.name}-prod/${databricks_mws_workspaces.this.workspace_id}/*",
          "${aws_s3_bucket.root.arn}/${local.region.name}-prod/${databricks_mws_workspaces.this.workspace_id}.*/*",
          "${aws_s3_bucket.root.arn}/${local.region.name}-prod/${databricks_mws_workspaces.this.workspace_id}/*",
        ]
        Condition = { StringEquals = { "aws:PrincipalTag/DatabricksAccountId" = var.databricks_account_id } }
      },
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = ["s3:*"]
        Resource  = [aws_s3_bucket.root.arn, "${aws_s3_bucket.root.arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
    ]
  })

  depends_on = [aws_s3_bucket_policy.root_bootstrap]
}

# ---------------------------------------------------------------------------
# Databricks account objects and the workspace.
# ---------------------------------------------------------------------------

resource "databricks_mws_credentials" "this" {
  provider         = databricks.account
  credentials_name = "${module.names.workspace_name}-credentials"
  role_arn         = aws_iam_role.cross_account.arn

  depends_on = [time_sleep.cross_account]
}

resource "databricks_mws_storage_configurations" "this" {
  provider                   = databricks.account
  account_id                 = var.databricks_account_id
  storage_configuration_name = "${module.names.workspace_name}-storage"
  bucket_name                = aws_s3_bucket.root.bucket

  depends_on = [aws_s3_bucket_policy.root_bootstrap]
}

resource "databricks_mws_vpc_endpoint" "this" {
  provider = databricks.account
  for_each = { rest = aws_vpc_endpoint.interface["rest"].id, relay = aws_vpc_endpoint.interface["relay"].id }

  account_id          = var.databricks_account_id
  aws_vpc_endpoint_id = each.value
  vpc_endpoint_name   = "${module.names.workspace_name}-${each.key}"
  region              = var.aws_region
}

resource "databricks_mws_networks" "this" {
  provider           = databricks.account
  account_id         = var.databricks_account_id
  network_name       = "${module.names.workspace_name}-network"
  vpc_id             = aws_vpc.this.id
  subnet_ids         = aws_subnet.compute[*].id
  security_group_ids = [aws_security_group.workspace.id]

  vpc_endpoints {
    rest_api        = [databricks_mws_vpc_endpoint.this["rest"].vpc_endpoint_id]
    dataplane_relay = [databricks_mws_vpc_endpoint.this["relay"].vpc_endpoint_id]
  }
}

# Front end stays public (IP allow list, SSO); private access is limited to this workspace's endpoint.
# Immutable: changing it means a new private access settings object.
resource "databricks_mws_private_access_settings" "this" {
  provider                     = databricks.account
  private_access_settings_name = "${module.names.workspace_name}-pas"
  region                       = var.aws_region
  public_access_enabled        = true
  private_access_level         = "ENDPOINT"
  allowed_vpc_endpoint_ids     = [databricks_mws_vpc_endpoint.this["rest"].vpc_endpoint_id]
}

resource "databricks_mws_workspaces" "this" {
  provider = databricks.account

  account_id                               = var.databricks_account_id
  workspace_name                           = module.names.workspace_name
  aws_region                               = var.aws_region
  pricing_tier                             = "ENTERPRISE"
  credentials_id                           = databricks_mws_credentials.this.credentials_id
  storage_configuration_id                 = databricks_mws_storage_configurations.this.storage_configuration_id
  network_id                               = databricks_mws_networks.this.network_id
  private_access_settings_id               = databricks_mws_private_access_settings.this.private_access_settings_id
  managed_services_customer_managed_key_id = var.managed_services_cmk_id
  storage_customer_managed_key_id          = databricks_mws_customer_managed_keys.workspace_storage.customer_managed_key_id
}

# The workspace API needs a moment after creation before workspace-level calls succeed.
resource "time_sleep" "workspace" {
  create_duration = "60s"
  depends_on      = [databricks_mws_workspaces.this]
}

module "core" {
  source = "../workspace-core"

  providers = {
    databricks.account   = databricks.account
    databricks.workspace = databricks.workspace
  }

  workspace_id           = databricks_mws_workspaces.this.workspace_id
  additional_s3_vpce_ids = [aws_vpc_endpoint.s3.id]

  prefix      = var.prefix
  zone        = var.zone
  function    = var.function
  environment = var.environment
  aws_region  = var.aws_region
  signals     = var.signals

  databricks_account_id = var.databricks_account_id
  metastore_id          = var.metastore_id

  admin_group_name         = var.admin_group_name
  uc_admin_group_name      = var.uc_admin_group_name
  user_group_name          = var.user_group_name
  human_catalog_privileges = var.human_catalog_privileges
  allowed_ip_cidrs         = var.allowed_ip_cidrs
  lockdown                 = var.lockdown

  egress_enforcement_mode     = var.egress_enforcement_mode
  s3_private_endpoint_enabled = var.s3_private_endpoint_enabled

  kms_admin_arns                = var.kms_admin_arns
  bucket_admin_principal_arns   = var.bucket_admin_principal_arns
  landing_writer_principal_arns = var.landing_writer_principal_arns
  object_lock_retention_days    = var.object_lock_retention_days
  cloudtrail_s3_bucket_name     = var.cloudtrail_s3_bucket_name

  alert_emails                   = var.alert_emails
  serverless_environment_version = var.serverless_environment_version
  manage_metastore               = var.manage_metastore

  depends_on = [time_sleep.workspace]
}
