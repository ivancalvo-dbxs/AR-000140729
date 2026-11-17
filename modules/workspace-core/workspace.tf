module "names" {
  source = "../naming"

  prefix      = var.prefix
  zone        = var.zone
  function    = var.function
  environment = var.environment
  aws_region  = var.aws_region
  signals     = var.signals
}

locals {
  workspace_name    = module.names.workspace_name
  workspace_catalog = module.names.workspace_catalog
}

resource "databricks_metastore_assignment" "this" {
  provider = databricks.account

  workspace_id = var.workspace_id
  metastore_id = var.metastore_id
}

# ---------------------------------------------------------------------------
# Identity: account groups come from the IdP; only the workload SP is created.
# ---------------------------------------------------------------------------

data "databricks_group" "admins" {
  provider     = databricks.account
  display_name = var.admin_group_name
}

data "databricks_group" "users" {
  provider     = databricks.account
  display_name = var.user_group_name
}

resource "databricks_service_principal" "workload" {
  provider     = databricks.account
  display_name = module.names.service_principal
}

# Permission assignment requires identity federation, which the metastore assignment turns on.
resource "databricks_mws_permission_assignment" "this" {
  provider = databricks.account
  for_each = {
    admins   = { id = data.databricks_group.admins.id, permission = "ADMIN" }
    users    = { id = data.databricks_group.users.id, permission = "USER" }
    workload = { id = databricks_service_principal.workload.id, permission = "USER" }
  }

  workspace_id = var.workspace_id
  principal_id = each.value.id
  permissions  = [each.value.permission]

  depends_on = [databricks_metastore_assignment.this]
}

# ---------------------------------------------------------------------------
# Front door and workspace hardening.
# ---------------------------------------------------------------------------

resource "databricks_workspace_conf" "this" {
  provider = databricks.workspace

  custom_config = merge(
    {
      enableIpAccessLists    = true
      enableTokensConfig     = false # no personal access tokens
      enableVerboseAuditLogs = true
      enableDbfsFileBrowser  = false
    },
    var.lockdown ? {
      enableResultsDownloading     = false
      enableNotebookTableClipboard = false
      enableExportNotebook         = false
    } : {}
  )

  depends_on = [databricks_mws_permission_assignment.this]
}

resource "databricks_ip_access_list" "allow" {
  provider = databricks.workspace

  label        = "front-door"
  list_type    = "ALLOW"
  ip_addresses = var.allowed_ip_cidrs

  depends_on = [databricks_workspace_conf.this]
}

resource "databricks_default_namespace_setting" "this" {
  provider = databricks.workspace

  namespace {
    value = databricks_catalog.signal[var.signals[0]].name
  }
}

# Workspace "users" group: every human gets workspace access (view job runs); SQL only outside lockdown.
data "databricks_group" "workspace_users" {
  provider     = databricks.workspace
  display_name = "users"

  depends_on = [databricks_mws_permission_assignment.this]
}

resource "databricks_entitlements" "workspace_users" {
  provider = databricks.workspace

  group_id              = data.databricks_group.workspace_users.id
  workspace_access      = true
  databricks_sql_access = !var.lockdown
  allow_cluster_create  = false
}

resource "databricks_restrict_workspace_admins_setting" "this" {
  provider = databricks.workspace
  count    = var.lockdown ? 1 : 0

  restrict_workspace_admins {
    status = "RESTRICT_TOKENS_AND_JOB_RUN_AS"
  }

  depends_on = [databricks_mws_permission_assignment.this]
}
