output "workspace_name" {
  value = databricks_mws_workspaces.this.workspace_name
}

output "workspace_id" {
  value = databricks_mws_workspaces.this.workspace_id
}

output "workspace_url" {
  description = "Also feeds the caller's databricks.workspace provider host."
  value       = databricks_mws_workspaces.this.workspace_url
}

output "service_principal_application_id" {
  description = "Run jobs and deployments as this SP."
  value       = databricks_service_principal.workload.application_id
}

output "catalogs" {
  value = { for k, c in databricks_catalog.signal : k => c.name }
}

output "buckets" {
  value = { for k, b in aws_s3_bucket.signal : k => b.bucket }
}

output "uc_role_arn" {
  value = aws_iam_role.uc.arn
}

output "ncc_id" {
  value = databricks_mws_network_connectivity_config.this.network_connectivity_config_id
}

output "s3_private_endpoint" {
  description = "Check connection_state is ESTABLISHED before setting s3_private_endpoint_enabled = true."
  value = {
    vpc_endpoint_id  = databricks_mws_ncc_private_endpoint_rule.s3.vpc_endpoint_id
    connection_state = databricks_mws_ncc_private_endpoint_rule.s3.connection_state
    enabled          = databricks_mws_ncc_private_endpoint_rule.s3.enabled
  }
}

output "network_policy_id" {
  value = databricks_account_network_policy.this.network_policy_id
}

output "checkpoints_volume_path" {
  value = databricks_volume.ops["checkpoints"].volume_path
}

output "libraries_volume_path" {
  value = databricks_volume.ops["libraries"].volume_path
}
