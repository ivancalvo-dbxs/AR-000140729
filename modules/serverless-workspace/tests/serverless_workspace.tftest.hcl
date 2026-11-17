# Offline checks with mocked providers: terraform init && terraform test

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "111122223333" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{}" }
  }
}
mock_provider "databricks" {
  alias = "account"
  # Real SCIM IDs are numeric strings.
  mock_data "databricks_group" {
    defaults = { id = "1001" }
  }
  mock_resource "databricks_service_principal" {
    defaults = { id = "2002", application_id = "00000000-0000-0000-0000-000000000002" }
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

run "dev_follows_naming_convention" {
  command = apply

  assert {
    condition     = databricks_mws_workspaces.this.workspace_name == "demo-shared-ingest-usw2-dev"
    error_message = "workspace name"
  }
  assert {
    condition     = databricks_account_network_policy.this.network_policy_id == "np-demo-shared-ingest-usw2-dev"
    error_message = "network policy id"
  }
  assert {
    condition     = databricks_mws_network_connectivity_config.this.name == "ncc-demo-shared-usw2-dev"
    error_message = "ncc name"
  }
  assert {
    condition     = databricks_service_principal.workload.display_name == "demo-sp-shared-ingest-usw2-dev"
    error_message = "service principal name"
  }
  assert {
    condition     = databricks_catalog.signal["raw"].name == "demo_shared_raw_dev"
    error_message = "catalog name"
  }
  assert {
    condition     = can(regex("^demo-shared-raw-usw2-dev-[a-z0-9]{6}$", aws_s3_bucket.signal["raw"].bucket))
    error_message = "bucket name"
  }
  assert {
    condition     = databricks_mws_workspaces.this.compute_mode == "SERVERLESS"
    error_message = "serverless workspace"
  }
  assert {
    condition     = databricks_workspace_conf.this.custom_config["enableTokensConfig"] == "false"
    error_message = "PATs must be off"
  }
  assert {
    condition     = length(databricks_grants.workspace_catalog) == 0 && length(databricks_restrict_workspace_admins_setting.this) == 0
    error_message = "dev is not locked down"
  }
  assert {
    condition     = databricks_entitlements.workspace_users.databricks_sql_access == true
    error_message = "dev keeps SQL"
  }
}

run "prd_lockdown" {
  command = apply

  variables {
    environment = "prd"
    lockdown    = true
    signals     = ["raw", "enriched"]
  }

  assert {
    condition     = databricks_entitlements.workspace_users.databricks_sql_access == false
    error_message = "prd humans lose SQL"
  }
  assert {
    condition     = databricks_grants.workspace_catalog[0].catalog == "demo_shared_ingest_usw2_prd"
    error_message = "workspace catalog revoked"
  }
  assert {
    condition     = databricks_workspace_conf.this.custom_config["enableResultsDownloading"] == "false"
    error_message = "downloads off"
  }
  assert {
    condition     = length(databricks_account_network_policy.this.egress.network_access.allowed_storage_destinations) == 2
    error_message = "egress allows exactly the workspace buckets"
  }
  assert {
    condition     = databricks_default_namespace_setting.this.namespace[0].value == "demo_shared_raw_prd"
    error_message = "default catalog is the first signal"
  }
}

run "prd_rejects_human_data_grants" {
  command = plan

  variables {
    environment              = "prd"
    lockdown                 = true
    human_catalog_privileges = { engineers = ["SELECT"] }
  }

  expect_failures = [databricks_mws_workspaces.this]
}

run "rejects_unknown_environment" {
  command = plan

  variables {
    environment = "prod"
  }

  expect_failures = [var.environment]
}
