# Scheduled monitoring job (Jobs Serverless, service principal) over system tables.
# The script lives in a UC volume, so only UC-granted principals can change what the SP runs.

locals {
  alert_lookback_hours = 24
}

resource "databricks_system_schema" "access" {
  provider = databricks.workspace
  count    = var.manage_metastore ? 1 : 0

  schema     = "access"
  depends_on = [databricks_metastore_assignment.this]
}

# Only the UC admin group may create storage credentials and external locations.
resource "databricks_grants" "metastore" {
  provider = databricks.workspace
  count    = var.manage_metastore ? 1 : 0

  metastore = var.metastore_id

  grant {
    principal  = var.uc_admin_group_name
    privileges = ["CREATE_STORAGE_CREDENTIAL", "CREATE_EXTERNAL_LOCATION"]
  }

  depends_on = [databricks_metastore_assignment.this]
}

# Databricks_grant (not _grants): system schemas are shared by every workspace on the metastore.
resource "databricks_grant" "system_catalog" {
  provider = databricks.workspace

  catalog    = "system"
  principal  = local.workload_sp
  privileges = ["USE_CATALOG"]

  depends_on = [databricks_metastore_assignment.this]
}

resource "databricks_grant" "system_schema" {
  provider = databricks.workspace
  for_each = toset(["billing", "access"])

  schema     = "system.${each.key}"
  principal  = local.workload_sp
  privileges = ["USE_SCHEMA", "SELECT"]

  depends_on = [databricks_system_schema.access]
}

resource "databricks_file" "security_alerts" {
  provider = databricks.workspace

  source = "${path.module}/files/security_alerts.py"
  path   = "${databricks_volume.ops["libraries"].volume_path}/monitoring/security_alerts.py"
}

resource "databricks_job" "security_alerts" {
  provider = databricks.workspace

  name = "${local.workspace_name}-security-alerts"

  run_as {
    service_principal_name = local.workload_sp
  }

  schedule {
    quartz_cron_expression = "0 0 6 * * ?" # daily, matching the 24h lookback so each finding alerts once
    timezone_id            = "UTC"
  }

  environment {
    environment_key = "default"
    spec {
      environment_version = var.serverless_environment_version
    }
  }

  task {
    task_key        = "security_alerts"
    environment_key = "default"

    spark_python_task {
      python_file = databricks_file.security_alerts.path
      parameters = [
        tostring(var.workspace_id),
        local.workspace_catalog,
        tostring(local.alert_lookback_hours),
      ]
    }
  }

  email_notifications {
    on_failure = var.alert_emails
  }

  depends_on = [databricks_grant.system_schema, databricks_grants.catalog]
}

# Humans can see job runs (dev and prd), never edit or run them as the SP.
resource "databricks_permissions" "security_alerts" {
  provider = databricks.workspace

  job_id = databricks_job.security_alerts.id

  access_control {
    group_name       = var.user_group_name
    permission_level = "CAN_VIEW"
  }
}
