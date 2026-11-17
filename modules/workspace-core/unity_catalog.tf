# Order matters (SRA pattern): credential -> role trusting its external ID -> IAM wait -> locations.
# ISOLATED securables created from this workspace are bound to it automatically.

resource "databricks_storage_credential" "this" {
  provider = databricks.workspace

  name           = local.uc_role_name
  owner          = var.uc_admin_group_name
  isolation_mode = "ISOLATION_MODE_ISOLATED"
  aws_iam_role {
    role_arn = local.uc_role_arn
  }

  depends_on = [databricks_metastore_assignment.this]
}

# UCMasterRole with the credential's ExternalId, plus the self-assume UC requires.
data "databricks_aws_unity_catalog_assume_role_policy" "uc" {
  provider = databricks.workspace

  aws_account_id = data.aws_caller_identity.current.account_id
  role_name      = local.uc_role_name
  external_id    = databricks_storage_credential.this.aws_iam_role[0].external_id
}

resource "aws_iam_role" "uc" {
  name               = local.uc_role_name
  assume_role_policy = data.databricks_aws_unity_catalog_assume_role_policy.uc.json
}

# Path-scoped: only this workspace's buckets and key. No SQS/SNS: Auto Loader uses directory listing.
resource "aws_iam_role_policy" "uc" {
  name = "uc-data-access"
  role = aws_iam_role.uc.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SignalBuckets"
        Effect = "Allow"
        Action = [
          "s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket", "s3:GetBucketLocation",
          "s3:ListBucketMultipartUploads", "s3:ListMultipartUploadParts", "s3:AbortMultipartUpload",
        ]
        Resource = flatten([for b in aws_s3_bucket.signal : [b.arn, "${b.arn}/*"]])
      },
      {
        Sid      = "DataKey"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey*"]
        Resource = [aws_kms_key.data.arn]
      },
      {
        Sid      = "SelfAssume"
        Effect   = "Allow"
        Action   = ["sts:AssumeRole"]
        Resource = [local.uc_role_arn]
      },
    ]
  })
}

resource "time_sleep" "iam_propagation" {
  create_duration = "60s"
  depends_on      = [aws_iam_role_policy.uc, aws_s3_bucket_policy.signal]
}

resource "databricks_external_location" "signal" {
  provider = databricks.workspace
  for_each = aws_s3_bucket.signal

  name               = each.value.bucket
  url                = "s3://${each.value.bucket}/"
  credential_name    = databricks_storage_credential.this.name
  owner              = var.uc_admin_group_name
  isolation_mode     = "ISOLATION_MODE_ISOLATED"
  enable_file_events = false

  depends_on = [time_sleep.iam_propagation]
}

resource "databricks_catalog" "signal" {
  provider = databricks.workspace
  for_each = databricks_external_location.signal

  name           = module.names.catalogs[each.key]
  storage_root   = "s3://${aws_s3_bucket.signal[each.key].bucket}/managed"
  isolation_mode = "ISOLATED"
  comment        = "${title(each.key)} signals (${var.environment}), managed by Terraform"
}

# Auto Loader checkpoints/schemas and pinned wheels live on customer-owned S3, never default storage.
resource "databricks_schema" "ops" {
  provider = databricks.workspace

  catalog_name = databricks_catalog.signal[var.signals[0]].name
  name         = "ops"
  comment      = "Auto Loader checkpoints and pinned libraries"
}

resource "databricks_volume" "ops" {
  provider = databricks.workspace
  for_each = toset(["checkpoints", "libraries"])

  catalog_name = databricks_schema.ops.catalog_name
  schema_name  = databricks_schema.ops.name
  name         = each.key
  volume_type  = "MANAGED"
}

# ---------------------------------------------------------------------------
# Grants. databricks_grants is authoritative: one resource per securable.
# ---------------------------------------------------------------------------

locals {
  workload_sp = databricks_service_principal.workload.application_id
  workload_catalog_privileges = [
    "USE_CATALOG", "USE_SCHEMA", "CREATE_SCHEMA", "CREATE_TABLE", "SELECT", "MODIFY", "READ_VOLUME", "WRITE_VOLUME",
  ]
}

resource "databricks_grants" "catalog" {
  provider = databricks.workspace
  for_each = databricks_catalog.signal

  catalog = each.value.name

  grant {
    principal  = local.workload_sp
    privileges = local.workload_catalog_privileges
  }

  dynamic "grant" {
    for_each = var.human_catalog_privileges
    content {
      principal  = grant.key
      privileges = grant.value
    }
  }
}

resource "databricks_grants" "external_location" {
  provider = databricks.workspace
  for_each = databricks_external_location.signal

  external_location = each.value.id

  grant {
    principal  = local.workload_sp
    privileges = ["READ_FILES"]
  }
}

# The storage credential has no grants on purpose: only its owner (uc_admin_group_name) can use it.

# Prod: nothing may land on default storage through the workspace catalog. Authoritative grants
# replace the default ones with BROWSE for admins only.
resource "databricks_grants" "workspace_catalog" {
  provider = databricks.workspace
  count    = var.lockdown ? 1 : 0

  catalog = local.workspace_catalog

  grant {
    principal  = var.admin_group_name
    privileges = ["BROWSE"]
  }

  depends_on = [databricks_metastore_assignment.this]
}
