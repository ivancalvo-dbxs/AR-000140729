# Serverless workspace (no customer VPC, no root bucket) plus the shared security baseline.

module "names" {
  source = "../naming"

  prefix      = var.prefix
  zone        = var.zone
  function    = var.function
  environment = var.environment
  aws_region  = var.aws_region
}

resource "databricks_mws_workspaces" "this" {
  provider = databricks.account

  account_id                               = var.databricks_account_id
  workspace_name                           = module.names.workspace_name
  aws_region                               = var.aws_region
  compute_mode                             = "SERVERLESS"
  pricing_tier                             = "ENTERPRISE"
  managed_services_customer_managed_key_id = var.managed_services_cmk_id
}

module "core" {
  source = "../workspace-core"

  providers = {
    databricks.account   = databricks.account
    databricks.workspace = databricks.workspace
  }

  workspace_id = databricks_mws_workspaces.this.workspace_id

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
}
