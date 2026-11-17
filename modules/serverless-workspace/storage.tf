data "aws_caller_identity" "current" {}

locals {
  # Databricks control-plane VPCs reach same-region buckets for UC operations (docs: ip-domain-region).
  databricks_control_plane_vpcs = {
    "us-west-2" = ["vpc-dc8086b9", "vpc-0c51983cc62e5ce0b"]
    "us-east-2" = [] # look up before using us-east-2; an empty list denies control-plane access
  }[var.aws_region]

  uc_role_name = "${var.prefix}-uc-${local.base}"
  uc_role_arn  = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${local.uc_role_name}"

  # Principals that may touch object data at all: the UC role (vended credentials) and producers.
  data_principal_arns = concat([local.uc_role_arn], var.landing_writer_principal_arns)
}

resource "random_string" "bucket_suffix" {
  length  = 6
  special = false
  upper   = false
}

# ---------------------------------------------------------------------------
# Per-workspace data key (alias omits the region: regional object).
# ---------------------------------------------------------------------------

resource "aws_kms_key" "data" {
  description         = "${local.workspace_name} S3 data"
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
        Sid       = "KeyUseThroughS3Only"
        Effect    = "Allow"
        Principal = { AWS = local.data_principal_arns }
        Action    = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:DescribeKey"]
        Resource  = "*"
        Condition = { StringEquals = { "kms:ViaService" = "s3.${var.aws_region}.amazonaws.com" } }
      },
    ]
  })

  # KMS rejects policies naming principals that do not exist yet.
  depends_on = [aws_iam_role.uc]
}

resource "aws_kms_alias" "data" {
  name          = "alias/${var.prefix}-${var.zone}-${var.function}-${var.environment}"
  target_key_id = aws_kms_key.data.key_id
}

# ---------------------------------------------------------------------------
# One bucket per signal: versioned, Object Lock, SSE-KMS, no ACLs, no public access.
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "signal" {
  for_each = toset(var.signals)

  bucket              = "${var.prefix}-${var.zone}-${each.key}-${local.region_code}-${var.environment}-${random_string.bucket_suffix.result}"
  object_lock_enabled = true
}

resource "aws_s3_bucket_ownership_controls" "signal" {
  for_each = aws_s3_bucket.signal

  bucket = each.value.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "signal" {
  for_each = aws_s3_bucket.signal

  bucket                  = each.value.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "signal" {
  for_each = aws_s3_bucket.signal

  bucket = each.value.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_object_lock_configuration" "signal" {
  for_each = aws_s3_bucket.signal

  bucket = each.value.id
  rule {
    default_retention {
      mode = "GOVERNANCE"
      days = var.object_lock_retention_days
    }
  }

  depends_on = [aws_s3_bucket_versioning.signal]
}

resource "aws_s3_bucket_lifecycle_configuration" "signal" {
  for_each = aws_s3_bucket.signal

  bucket = each.value.id
  rule {
    id     = "expire-noncurrent-after-retention"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = var.object_lock_retention_days
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.signal]
}

resource "aws_s3_bucket_server_side_encryption_configuration" "signal" {
  for_each = aws_s3_bucket.signal

  bucket = each.value.id
  rule {
    bucket_key_enabled = true
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.data.arn
    }
  }
}

data "aws_iam_policy_document" "bucket" {
  for_each = aws_s3_bucket.signal

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [each.value.arn, "${each.value.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  # Block governance bypass: only UC-vended credentials (and producers) touch data. Admins included.
  statement {
    sid       = "DenyDataAccessOutsideUnityCatalog"
    effect    = "Deny"
    actions   = ["s3:GetObject*", "s3:PutObject*", "s3:DeleteObject*", "s3:RestoreObject"]
    resources = ["${each.value.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "ArnNotEquals"
      variable = "aws:PrincipalArn"
      values   = local.data_principal_arns
    }
  }

  # Listing reveals object names; admins keep it because HeadBucket (every Terraform refresh) needs s3:ListBucket.
  statement {
    sid       = "DenyListingOutsideUnityCatalogAndAdmins"
    effect    = "Deny"
    actions   = ["s3:ListBucket*"]
    resources = [each.value.arn]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "ArnNotEquals"
      variable = "aws:PrincipalArn"
      values   = concat(local.data_principal_arns, var.bucket_admin_principal_arns)
    }
  }

  dynamic "statement" {
    for_each = length(var.landing_writer_principal_arns) > 0 ? [1] : []
    content {
      sid           = "DenyProducersOutsideLanding"
      effect        = "Deny"
      actions       = ["s3:*"]
      not_resources = ["${each.value.arn}/landing/*"]
      principals {
        type        = "*"
        identifiers = ["*"]
      }
      condition {
        test     = "ArnEquals"
        variable = "aws:PrincipalArn"
        values   = var.landing_writer_principal_arns
      }
    }
  }

  # Pinned to the NCC private endpoint instead of IP ranges (compensating control for stable egress IPs).
  dynamic "statement" {
    for_each = var.s3_private_endpoint_enabled ? [1] : []
    content {
      sid       = "DenyOutsidePrivateEndpoint"
      effect    = "Deny"
      actions   = ["s3:*"]
      resources = [each.value.arn, "${each.value.arn}/*"]
      principals {
        type        = "*"
        identifiers = ["*"]
      }
      condition {
        test     = "StringNotEqualsIfExists"
        variable = "aws:SourceVpce"
        values   = [databricks_mws_ncc_private_endpoint_rule.s3.vpc_endpoint_id]
      }
      condition {
        test     = "StringNotEqualsIfExists"
        variable = "aws:SourceVpc"
        values   = local.databricks_control_plane_vpcs
      }
      condition {
        test     = "ArnNotEquals"
        variable = "aws:PrincipalArn"
        values   = concat(var.bucket_admin_principal_arns, var.landing_writer_principal_arns)
      }
    }
  }
}

resource "aws_s3_bucket_policy" "signal" {
  for_each = aws_s3_bucket.signal

  bucket = each.value.id
  policy = data.aws_iam_policy_document.bucket[each.key].json

  depends_on = [aws_s3_bucket_public_access_block.signal]
}

# ---------------------------------------------------------------------------
# S3 data events, joined with UC credential vending in system.access.audit.
# ---------------------------------------------------------------------------

resource "aws_cloudtrail" "s3_data" {
  name                          = "${local.workspace_name}-s3-data"
  s3_bucket_name                = var.cloudtrail_s3_bucket_name
  include_global_service_events = false
  is_multi_region_trail         = false
  enable_log_file_validation    = true

  advanced_event_selector {
    name = "S3 data events on signal buckets"
    field_selector {
      field  = "eventCategory"
      equals = ["Data"]
    }
    field_selector {
      field  = "resources.type"
      equals = ["AWS::S3::Object"]
    }
    field_selector {
      field       = "resources.ARN"
      starts_with = [for b in aws_s3_bucket.signal : "${b.arn}/"]
    }
  }
}
