# Mirrors modules/classic-workspace/variables.tf (except serverless_environment_version, kept at the module default).

# ---------------------------------------------------------------------------
# Identity of the workspace. Every name is derived from these.
# ---------------------------------------------------------------------------

variable "prefix" {
  description = "Short organisation/platform prefix that starts every resource name (lowercase letters and digits, 2-10 chars)."
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9]{1,9}$", var.prefix))
    error_message = "prefix must be 2-10 lowercase letters or digits, starting with a letter."
  }
  validation {
    # Network policy IDs are limited to 32 characters by the API.
    condition     = length("np-${var.prefix}-${var.zone}-${var.function}-usw2-${var.environment}") <= 32
    error_message = "prefix is too long: the network policy ID np-<prefix>-<zone>-<function>-<region>-<env> must be at most 32 characters."
  }
}

variable "zone" {
  description = "Security signal zone. 'reserved' is meant for a separate Databricks account."
  type        = string
  validation {
    condition     = contains(["shared", "reserved"], var.zone)
    error_message = "zone must be one of: shared, reserved."
  }
}

variable "function" {
  description = "Workspace function: ingest (SPs load data), consume (read-only bindings), eng, sbx."
  type        = string
  validation {
    condition     = contains(["ingest", "consume", "eng", "sbx"], var.function)
    error_message = "function must be one of: ingest, consume, eng, sbx."
  }
}

variable "environment" {
  description = "Environment token: dev, qal, e2e or prd."
  type        = string
  validation {
    condition     = contains(["dev", "qal", "e2e", "prd"], var.environment)
    error_message = "environment must be one of: dev, qal, e2e, prd."
  }
}

variable "aws_region" {
  description = "AWS region of the workspace. Only regions with a naming token are allowed."
  type        = string
  default     = "us-west-2"
  validation {
    condition     = contains(["us-west-2", "us-east-2"], var.aws_region)
    error_message = "aws_region must be us-west-2 (usw2) or us-east-2 (use2)."
  }
}

variable "signals" {
  description = "Signal types this workspace owns. One S3 bucket, external location and catalog is created per signal. The first one is the workspace default catalog."
  type        = list(string)
  default     = ["raw"]
  validation {
    condition     = length(var.signals) > 0 && alltrue([for s in var.signals : contains(["raw", "enriched", "alerts", "correlation"], s)])
    error_message = "signals must be a non-empty list of: raw, enriched, alerts, correlation."
  }
}

# ---------------------------------------------------------------------------
# Account-level inputs (created once, see live/account).
# ---------------------------------------------------------------------------

variable "databricks_account_id" {
  description = "Databricks account ID (UUID)."
  type        = string
  validation {
    condition     = can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", var.databricks_account_id))
    error_message = "databricks_account_id must be a UUID, not a placeholder."
  }
}

variable "metastore_id" {
  description = "Unity Catalog metastore ID for the region."
  type        = string
}

variable "managed_services_cmk_id" {
  description = "Databricks customer-managed key configuration ID (use case MANAGED_SERVICES), from live/account. Encrypts control-plane data (notebooks, secrets, queries)."
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
  validation {
    condition     = !var.lockdown || length(var.human_catalog_privileges) == 0
    error_message = "lockdown = true forbids human data grants (human_catalog_privileges must be empty)."
  }
}

variable "allowed_ip_cidrs" {
  description = "Front-door IP allow list (UI and API). Must include the CI/Terraform egress IP, or the next apply locks itself out."
  type        = list(string)
  validation {
    condition     = length(var.allowed_ip_cidrs) > 0 && alltrue([for c in var.allowed_ip_cidrs : can(cidrhost(c, 0))])
    error_message = "allowed_ip_cidrs must be a non-empty list of valid CIDRs."
  }
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
  validation {
    condition     = contains(["DRY_RUN", "ENFORCED"], var.egress_enforcement_mode)
    error_message = "egress_enforcement_mode must be DRY_RUN or ENFORCED."
  }
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
  validation {
    condition     = length(var.kms_admin_arns) > 0
    error_message = "kms_admin_arns must not be empty, or the key becomes unmanageable."
  }
}

variable "bucket_admin_principal_arns" {
  description = "IAM principals allowed to manage bucket configuration from outside the private endpoint (Terraform deployer, break-glass). They are still denied object reads and writes."
  type        = list(string)
  validation {
    condition     = length(var.bucket_admin_principal_arns) > 0
    error_message = "bucket_admin_principal_arns must not be empty, or the bucket policy locks Terraform out."
  }
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
  validation {
    condition     = var.object_lock_retention_days >= 1
    error_message = "object_lock_retention_days must be >= 1."
  }
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
  validation {
    condition     = length(var.alert_emails) > 0
    error_message = "alert_emails must not be empty."
  }
}

variable "manage_metastore" {
  description = "Manage metastore-wide objects from this workspace: enable system.access and restrict credential/location creation to uc_admin_group_name. Set true in exactly one workspace per metastore."
  type        = bool
  default     = false
}

# ---------------------------------------------------------------------------
# Classic compute plane (customer-managed VPC).
# ---------------------------------------------------------------------------

variable "vpc_cidr" {
  description = "CIDR of the compute VPC. Half goes to two cluster subnets, a small slice to two PrivateLink subnets. Must not overlap networks it may later be peered with."
  type        = string
  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0)) && tonumber(split("/", var.vpc_cidr)[1]) >= 16 && tonumber(split("/", var.vpc_cidr)[1]) <= 22
    error_message = "vpc_cidr must be a valid CIDR between /16 and /22."
  }
}

variable "flow_logs_s3_bucket_arn" {
  description = "Existing S3 bucket ARN receiving VPC flow logs. Its policy must allow delivery.logs.amazonaws.com."
  type        = string
}

variable "enhanced_security_monitoring" {
  description = "Enable enhanced security monitoring (hardened image, antivirus and file integrity monitoring agents) on classic compute."
  type        = bool
  default     = true
}

variable "compliance_standards" {
  description = "Compliance security profile standards, for example [\"HIPAA\"] or [\"PCI_DSS\"]. [\"NONE\"] turns the profile on without a standard. Empty keeps it off. The profile cannot be turned off once on."
  type        = list(string)
  default     = []
}

variable "existing_workspace_id" {
  description = "Numeric ID of a workspace created outside Terraform, to import instead of create."
  type        = number
  default     = null
}

variable "tags" {
  description = "Tags applied to every AWS resource."
  type        = map(string)
  default     = {}
}
