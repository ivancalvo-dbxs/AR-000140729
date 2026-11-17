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
  mock_data "databricks_group" {
    defaults = { id = "1001" }
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
  environment                 = "prd"
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
  lockdown                    = true
}

run "serverless_workspace" {
  command = apply

  assert {
    condition     = databricks_mws_workspaces.this.workspace_name == "demo-shared-ingest-usw2-prd"
    error_message = "workspace name"
  }
  assert {
    condition     = databricks_mws_workspaces.this.compute_mode == "SERVERLESS"
    error_message = "serverless compute mode"
  }
  assert {
    condition     = databricks_mws_workspaces.this.managed_services_customer_managed_key_id == "cmk"
    error_message = "managed-services CMK"
  }
  assert {
    condition     = output.catalogs["raw"] == "demo_shared_raw_prd"
    error_message = "core wired in"
  }
}

run "rejects_human_data_grants_in_lockdown" {
  command = plan
  variables {
    human_catalog_privileges = { engineers = ["SELECT"] }
  }
  expect_failures = [var.human_catalog_privileges]
}

run "rejects_network_policy_id_over_32_chars" {
  command = plan
  variables {
    prefix   = "abcdefghij"
    zone     = "reserved"
    function = "consume"
  }
  expect_failures = [var.prefix]
}

run "rejects_unknown_environment" {
  command = plan
  variables {
    environment = "prod"
  }
  expect_failures = [var.environment]
}
