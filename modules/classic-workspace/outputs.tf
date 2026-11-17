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
  value = module.core.service_principal_application_id
}

output "catalogs" {
  value = module.core.catalogs
}

output "buckets" {
  value = module.core.buckets
}

output "uc_role_arn" {
  value = module.core.uc_role_arn
}

output "ncc_id" {
  value = module.core.ncc_id
}

output "s3_private_endpoint" {
  value = module.core.s3_private_endpoint
}

output "network_policy_id" {
  value = module.core.network_policy_id
}

output "checkpoints_volume_path" {
  value = module.core.checkpoints_volume_path
}

output "libraries_volume_path" {
  value = module.core.libraries_volume_path
}

output "vpc_id" {
  value = aws_vpc.this.id
}

output "compute_subnet_ids" {
  value = aws_subnet.compute[*].id
}

output "security_group_id" {
  value = aws_security_group.workspace.id
}

output "root_bucket" {
  value = aws_s3_bucket.root.bucket
}

output "cross_account_role_arn" {
  value = aws_iam_role.cross_account.arn
}

output "cluster_policy_id" {
  description = "Hardened cluster policy; the only way people (dev) or the workload SP create classic clusters."
  value       = databricks_cluster_policy.hardened.id
}
