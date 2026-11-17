# Internal: the naming convention in one place. Pure function, no resources or providers.
# Inputs are validated by the public modules (serverless-workspace, classic-workspace).

variable "prefix" { type = string }
variable "zone" { type = string }
variable "function" { type = string }
variable "environment" { type = string }
variable "aws_region" { type = string }
variable "signals" {
  type    = list(string)
  default = []
}

locals {
  region_code = { "us-west-2" = "usw2", "us-east-2" = "use2" }[var.aws_region]
  base        = "${var.prefix}-${var.zone}-${var.function}-${local.region_code}-${var.environment}"
}

output "region_code" { value = local.region_code }
output "base" { value = local.base }
output "workspace_name" { value = local.base }
output "network_policy_id" { value = "np-${local.base}" }
output "ncc_name" { value = "ncc-${var.prefix}-${var.zone}-${local.region_code}-${var.environment}" }
output "service_principal" { value = "${var.prefix}-sp-${var.zone}-${var.function}-${local.region_code}-${var.environment}" }
output "uc_role" { value = "${var.prefix}-uc-${var.zone}-${var.function}-${local.region_code}-${var.environment}" }
output "data_kms_alias" { value = "alias/${var.prefix}-${var.zone}-${var.function}-${var.environment}" }

# Buckets get a random 6-character suffix appended by the caller.
output "signal_bucket_prefixes" {
  value = { for s in var.signals : s => "${var.prefix}-${var.zone}-${s}-${local.region_code}-${var.environment}" }
}

output "catalogs" {
  value = { for s in var.signals : s => "${var.prefix}_${var.zone}_${s}_${var.environment}" }
}

# Serverless and UC-enabled workspaces get a workspace catalog named after the workspace.
output "workspace_catalog" { value = replace(local.base, "-", "_") }
