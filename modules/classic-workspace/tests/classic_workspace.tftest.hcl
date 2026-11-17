# Offline checks with mocked providers: terraform init && terraform test

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "111122223333" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{}" }
  }
  mock_data "aws_availability_zones" {
    defaults = { names = ["us-west-2a", "us-west-2b", "us-west-2c"] }
  }
  mock_data "aws_prefix_list" {
    defaults = { id = "pl-12345678" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::111122223333:role/cross-account" }
  }
}
mock_provider "databricks" {
  alias = "account"
  mock_data "databricks_group" {
    defaults = { id = "1001" }
  }
  mock_data "databricks_aws_assume_role_policy" {
    defaults = { json = "{}" }
  }
  mock_data "databricks_aws_crossaccount_policy" {
    defaults = { json = "{}" }
  }
  mock_data "databricks_aws_bucket_policy" {
    defaults = { json = "{}" }
  }
  mock_resource "databricks_service_principal" {
    defaults = { id = "2002", application_id = "00000000-0000-0000-0000-000000000002" }
  }
  mock_resource "databricks_mws_workspaces" {
    defaults = { workspace_id = 1234567890 }
  }
}
mock_provider "databricks" {
  alias = "workspace"
  mock_data "databricks_aws_unity_catalog_assume_role_policy" {
    defaults = { json = "{}" }
  }
}

variables {
  prefix                      = "demo"
  zone                        = "shared"
  function                    = "ingest"
  environment                 = "dev"
  vpc_cidr                    = "10.20.0.0/16"
  flow_logs_s3_bucket_arn     = "arn:aws:s3:::flow-logs"
  databricks_account_id       = "11111111-2222-3333-4444-555555555555"
  metastore_id                = "metastore"
  managed_services_cmk_id     = "cmk"
  admin_group_name            = "admins"
  uc_admin_group_name         = "uc-admins"
  user_group_name             = "engineers"
  allowed_ip_cidrs            = ["10.0.0.0/8"]
  kms_admin_arns              = ["arn:aws:iam::111122223333:role/deployer"]
  bucket_admin_principal_arns = ["arn:aws:iam::111122223333:role/deployer"]
  cloudtrail_s3_bucket_name   = "trail"
  alert_emails                = ["sec@example.com"]
}

run "dev_classic_workspace" {
  command = apply

  assert {
    condition     = databricks_mws_workspaces.this.workspace_name == "demo-shared-ingest-usw2-dev" && databricks_mws_workspaces.this.compute_mode == null
    error_message = "classic workspace name and compute mode"
  }
  assert {
    condition     = databricks_mws_workspaces.this.storage_customer_managed_key_id == databricks_mws_customer_managed_keys.workspace_storage.customer_managed_key_id
    error_message = "workspace storage CMK"
  }
  assert {
    condition     = aws_subnet.compute[*].cidr_block == ["10.20.0.0/18", "10.20.64.0/18"] && aws_subnet.privatelink[*].cidr_block == ["10.20.128.0/22", "10.20.132.0/22"]
    error_message = "subnet layout"
  }
  assert {
    condition     = alltrue([for s in aws_subnet.compute : !s.map_public_ip_on_launch])
    error_message = "no public IPs"
  }
  assert {
    condition     = alltrue([for e in aws_vpc_endpoint.interface : e.private_dns_enabled])
    error_message = "private DNS on every interface endpoint"
  }
  assert {
    condition     = databricks_mws_private_access_settings.this.private_access_level == "ENDPOINT"
    error_message = "private access limited to this workspace's endpoint"
  }
  assert {
    condition     = length(databricks_permissions.hardened_policy.access_control) == 2
    error_message = "dev: engineers and SP can use the cluster policy"
  }
  assert {
    condition     = length(databricks_enhanced_security_monitoring_workspace_setting.this) == 1 && length(databricks_compliance_security_profile_workspace_setting.this) == 0
    error_message = "ESM on, CSP off by default"
  }
}

run "prd_classic_lockdown" {
  command = apply

  variables {
    environment          = "prd"
    lockdown             = true
    compliance_standards = ["HIPAA"]
  }

  assert {
    condition     = length(databricks_permissions.hardened_policy.access_control) == 1
    error_message = "prd: only the SP can use the cluster policy"
  }
  assert {
    condition     = length(databricks_compliance_security_profile_workspace_setting.this) == 1 && length(databricks_automatic_cluster_update_workspace_setting.this) == 1
    error_message = "CSP requires automatic cluster update"
  }
}

run "rejects_small_vpc" {
  command = plan
  variables {
    vpc_cidr = "10.20.0.0/24"
  }
  expect_failures = [var.vpc_cidr]
}
