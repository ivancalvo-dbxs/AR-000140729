# Internal module: inputs are validated by the public modules (serverless-workspace, classic-workspace).

variable "workspace_id" {
  description = "Numeric ID of the workspace this baseline applies to."
  type        = number
}

variable "additional_s3_vpce_ids" {
  description = "Extra VPC endpoint IDs allowed by the bucket policies once the private endpoint is enabled (for example the S3 gateway endpoint of a classic compute VPC)."
  type        = list(string)
  default     = []
}

# ---------------------------------------------------------------------------
# Identity of the workspace. Every name is derived from these.
# ---------------------------------------------------------------------------

variable "prefix" {
  description = "Short organisation/platform prefix that starts every resource name (lowercase letters and digits, 2-10 chars)."
  type        = string
}

variable "zone" {
  description = "Security signal zone. 'reserved' is meant for a separate Databricks account."
  type        = string
}

variable "function" {
  description = "Workspace function: ingest (SPs load data), consume (read-only bindings), eng, sbx."
  type        = string
}

variable "environment" {
  description = "Environment token: dev, qal, e2e or prd."
  type        = string
}

variable "aws_region" {
  description = "AWS region of the workspace. Only regions with a naming token are allowed."
  type        = string
  default     = "us-west-2"
}

variable "signals" {
  description = "Signal types this workspace owns. One S3 bucket, external location and catalog is created per signal. The first one is the workspace default catalog."
  type        = list(string)
  default     = ["raw"]
}

# ---------------------------------------------------------------------------
# Account-level inputs (created once, see live/account).
# ---------------------------------------------------------------------------

variable "databricks_account_id" {
  description = "Databricks account ID (UUID)."
  type        = string
}

variable "metastore_id" {
  description = "Unity Catalog metastore ID for the region."
  type        = string
}

# ---------------------------------------------------------------------------
# Access.
# ---------------------------------------------------------------------------

variable "admin_group_name" {
  description = "Account-level (IdP-synced) group assigned as workspace ADMIN. Dev: 1-2 admins, prd: break-glass."
  type        = string
}

variable "uc_admin_group_name" {
  description = "Account-level group that owns storage credentials and external locations (and, with manage_metastore, is the only one allowed to create them). The Terraform deployer must be a member or a metastore admin."
  type        = string
}

variable "user_group_name" {
  description = "Account-level (IdP-synced) group assigned as workspace USER (engineers)."
  type        = string
}

variable "human_catalog_privileges" {
  description = "UC privileges granted to human groups on every catalog of this workspace, keyed by group name. Must be empty when lockdown = true."
  type        = map(list(string))
  default     = {}
}

variable "allowed_ip_cidrs" {
  description = "Front-door IP allow list (UI and API). Must include the CI/Terraform egress IP, or the next apply locks itself out."
  type        = list(string)
}

variable "lockdown" {
  description = "Production compensating boundary: no human data grants, no Databricks SQL entitlement, no downloads/exports, workspace catalog revoked, admins restricted on tokens and job run_as."
  type        = bool
  default     = false
}

# ---------------------------------------------------------------------------
# Network.
# ---------------------------------------------------------------------------

variable "egress_enforcement_mode" {
  description = "Serverless egress policy mode. Roll out DRY_RUN first, then ENFORCED."
  type        = string
  default     = "ENFORCED"
}

variable "s3_private_endpoint_enabled" {
  description = "Activate the NCC S3 private endpoint and pin the bucket policies to it. The provider can only enable the rule after it exists, so set false on the first apply and true once the rule is ESTABLISHED."
  type        = bool
  default     = false
}

# ---------------------------------------------------------------------------
# Storage.
# ---------------------------------------------------------------------------

variable "kms_admin_arns" {
  description = "IAM principals that administer (but cannot use) the per-workspace data KMS key. Must include the Terraform deployer."
  type        = list(string)
}

variable "bucket_admin_principal_arns" {
  description = "IAM principals allowed to manage bucket configuration from outside the private endpoint (Terraform deployer, break-glass). They are still denied object reads and writes."
  type        = list(string)
}

variable "landing_writer_principal_arns" {
  description = "IAM principals of upstream signal producers allowed to put objects under landing/ in the bucket. Auto Loader reads from there."
  type        = list(string)
  default     = []
}

variable "object_lock_retention_days" {
  description = "Default S3 Object Lock retention (GOVERNANCE mode) on every object version. Noncurrent versions expire after this."
  type        = number
  default     = 30
}

variable "cloudtrail_s3_bucket_name" {
  description = "Existing CloudTrail log bucket. A trail recording S3 data events on this workspace's buckets is created to correlate with UC credential vending."
  type        = string
}

# ---------------------------------------------------------------------------
# Monitoring.
# ---------------------------------------------------------------------------

variable "alert_emails" {
  description = "Recipients of the security monitoring job failure notifications."
  type        = list(string)
}

variable "serverless_environment_version" {
  description = "Pinned serverless environment version for jobs created by this module."
  type        = string
  default     = "4"
}

variable "manage_metastore" {
  description = "Manage metastore-wide objects from this workspace: enable system.access and restrict credential/location creation to uc_admin_group_name. Set true in exactly one workspace per metastore."
  type        = bool
  default     = false
}
