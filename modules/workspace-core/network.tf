# Serverless egress: NCC with an S3 private endpoint, plus a deny-all network policy
# that only allows this workspace's buckets.

# shortcut: the NCC is per zone/region/env by naming, but created per workspace. Move it to a
# shared layer (and list every workspace's buckets in the S3 rule) when a 2nd workspace joins an env.
resource "databricks_mws_network_connectivity_config" "this" {
  provider = databricks.account

  name   = module.names.ncc_name
  region = var.aws_region
}

resource "databricks_mws_ncc_private_endpoint_rule" "s3" {
  provider = databricks.account

  network_connectivity_config_id = databricks_mws_network_connectivity_config.this.network_connectivity_config_id
  endpoint_service               = "com.amazonaws.${var.aws_region}.s3"
  resource_names                 = [for b in aws_s3_bucket.signal : b.bucket]
  enabled                        = var.s3_private_endpoint_enabled
}

resource "databricks_mws_ncc_binding" "this" {
  provider = databricks.account

  network_connectivity_config_id = databricks_mws_network_connectivity_config.this.network_connectivity_config_id
  workspace_id                   = var.workspace_id
}

resource "databricks_account_network_policy" "this" {
  provider = databricks.account

  account_id        = var.databricks_account_id
  network_policy_id = module.names.network_policy_id

  egress = {
    network_access = {
      restriction_mode = "RESTRICTED_ACCESS"
      allowed_storage_destinations = [for b in aws_s3_bucket.signal : {
        bucket_name              = b.bucket
        region                   = var.aws_region
        storage_destination_type = "AWS_S3"
      }]
      policy_enforcement = {
        enforcement_mode = var.egress_enforcement_mode
      }
    }
  }
}

resource "databricks_workspace_network_option" "this" {
  provider = databricks.account

  workspace_id      = var.workspace_id
  network_policy_id = databricks_account_network_policy.this.network_policy_id
}
