# Classic compute hardening: monitoring agents, optional compliance profile, and one cluster policy.

resource "databricks_enhanced_security_monitoring_workspace_setting" "this" {
  provider = databricks.workspace
  count    = var.enhanced_security_monitoring ? 1 : 0

  enhanced_security_monitoring_workspace {
    is_enabled = true
  }

  depends_on = [module.core]
}

resource "databricks_compliance_security_profile_workspace_setting" "this" {
  provider = databricks.workspace
  count    = length(var.compliance_standards) > 0 ? 1 : 0

  compliance_security_profile_workspace {
    is_enabled           = true
    compliance_standards = var.compliance_standards
  }

  depends_on = [module.core]
}

# The compliance security profile requires automatic cluster updates.
resource "databricks_automatic_cluster_update_workspace_setting" "this" {
  provider = databricks.workspace
  count    = length(var.compliance_standards) > 0 ? 1 : 0

  automatic_cluster_update_workspace {
    enabled = true
  }

  depends_on = [module.core]
}

# Nobody has unrestricted cluster creation (core removes it from "users"); clusters come from this policy.
resource "databricks_cluster_policy" "hardened" {
  provider = databricks.workspace

  name = "${module.names.workspace_name}-hardened"
  definition = jsonencode({
    data_security_mode                     = { type = "allowlist", values = ["USER_ISOLATION", "SINGLE_USER"], defaultValue = "USER_ISOLATION" }
    "aws_attributes.instance_profile_arn"  = { type = "forbidden" } # all data access through Unity Catalog
    "docker_image.url"                     = { type = "forbidden" } # no custom images
    "init_scripts.*.workspace.destination" = { type = "forbidden" } # no host agents
    "init_scripts.*.volumes.destination"   = { type = "forbidden" }
    "init_scripts.*.s3.destination"        = { type = "forbidden" }
    enable_local_disk_encryption           = { type = "fixed", value = true }
    autotermination_minutes                = { type = "range", minValue = 10, maxValue = 120, defaultValue = 30 }
    spark_version                          = { type = "unlimited", defaultValue = "auto:latest-lts" }
  })

  depends_on = [module.core]
}

# Dev: engineers and the workload SP. Prod (lockdown): the workload SP only.
resource "databricks_permissions" "hardened_policy" {
  provider = databricks.workspace

  cluster_policy_id = databricks_cluster_policy.hardened.id

  access_control {
    service_principal_name = module.core.service_principal_application_id
    permission_level       = "CAN_USE"
  }

  dynamic "access_control" {
    for_each = var.lockdown ? [] : [var.user_group_name]
    content {
      group_name       = access_control.value
      permission_level = "CAN_USE"
    }
  }
}
