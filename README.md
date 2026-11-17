# Hardened serverless Databricks workspaces on AWS

Terraform for a security data platform on Databricks: hardened **serverless** workspaces, one per environment, under one Databricks account and control plane.
Dev has every service on for engineers.
Prod runs only an ingestion job (Jobs Serverless, Auto Loader) inside a compensating boundary: no human data access, no SQL for humans, no downloads, deny-all egress.

The code follows the patterns of the Databricks [AI Platform Kit](https://github.com/databricks-solutions/ai-platform-kit) skills (platform provisioning, private networking, Unity Catalog setup, identity governance, workspace config) and the serverless modules of the [Security Reference Architecture](https://github.com/databricks/terraform-databricks-sra).

> **Status: not yet applied to a real environment.**
> The code passes `terraform validate` and offline tests with mocked providers, but nothing here has been planned or applied against AWS or Databricks.
> Review the [assumptions](#assumptions-to-confirm-on-first-apply) and run the first apply in dev.

## Contents

- [Architecture](#architecture)
- [Repository layout](#repository-layout)
- [Naming convention](#naming-convention)
- [What each control maps to](#what-each-control-maps-to)
- [Prerequisites](#prerequisites)
- [Deploy](#deploy)
- [Run and operate](#run-and-operate)
- [Gaps: not covered by this code](#gaps-not-covered-by-this-code)
- [Assumptions to confirm on first apply](#assumptions-to-confirm-on-first-apply)
- [Tests](#tests)

## Architecture

```
                         Databricks account (one control plane)
 People ──SSO──►  ┌────────────────────────────────────────────────────────────┐
 (IP allowlist,   │ default-policy: deny all egress · legacy features off      │
  no PATs)        │ Managed-services CMK (customer KMS)                         │
                  │                                                            │
                  │  <prefix>-shared-ingest-usw2-dev   <prefix>-...-prd        │
                  │  ├─ network policy: only its buckets   (same, ENFORCED)     │
                  │  ├─ NCC + S3 private endpoint          (lockdown = true)    │
                  │  ├─ UC catalogs bound to this workspace only                │
                  │  ├─ workload service principal                              │
                  │  └─ daily security alert job                                │
                  └──────────────┬─────────────────────────────────────────────┘
                                 │ private endpoint, UC-vended credentials
                  ┌──────────────▼─────────────────────────────────────────────┐
                  │ Customer AWS account                                       │
                  │  S3 per signal: versioned, Object Lock, SSE-KMS, no ACLs    │
                  │  UC IAM role per workspace (path-scoped)                    │
                  │  KMS keys · CloudTrail S3 data events                       │
                  └────────────────────────────────────────────────────────────┘
```

## Repository layout

```
modules/serverless-workspace/   Reusable module: one serverless workspace and everything around it
  tests/                        terraform test with mocked providers
  files/security_alerts.py      Script run by the security alert job
live/account/                   Account-wide controls, applied once per Databricks account
live/workspace/                 Root used for every workspace; one state and one tfvars file per workspace
  envs/                         dev and prd examples (tfvars and backend config)
```

The module is called once per workspace, each call in its own Terraform state.
Dev and prod differ only in their tfvars file, so the two cannot drift in code.

## Naming convention

Every name is derived from five inputs: `prefix`, `zone`, `function`, `aws_region` and `environment`.
Callers cannot set names directly, so every environment follows the same convention.

| Input | Allowed values | Meaning |
|---|---|---|
| `prefix` | 2-10 lowercase letters or digits | Organisation or platform prefix |
| `zone` | `shared`, `reserved` | Signal zone; `reserved` is meant for a separate Databricks account |
| `function` | `ingest`, `consume`, `eng`, `sbx` | Service principals load data / people read / engineering builds / sandbox |
| `aws_region` | `us-west-2` (`usw2`), `us-east-2` (`use2`) | Region and its naming token |
| `environment` | `dev`, `qal`, `e2e`, `prd` | Development / quality / end-to-end pre-production / production |
| `signals` | `raw`, `enriched`, `alerts`, `correlation` | One bucket, external location and catalog per signal type |

| Object | Pattern | Example (`prefix = "acme"`) |
|---|---|---|
| Workspace | `<prefix>-<zone>-<function>-<region>-<env>` | `acme-shared-ingest-usw2-prd` |
| Catalog (per signal) | `<prefix>_<zone>_<signal>_<env>` | `acme_shared_raw_prd` |
| S3 bucket (per signal) | `<prefix>-<zone>-<signal>-<region>-<env>-<rand6>` | `acme-shared-raw-usw2-prd-x1y2z3` |
| Network policy | `np-<prefix>-<zone>-<function>-<region>-<env>` (max 32 chars) | `np-acme-shared-ingest-usw2-prd` |
| NCC | `ncc-<prefix>-<zone>-<region>-<env>` | `ncc-acme-shared-usw2-prd` |
| Service principal | `<prefix>-sp-<zone>-<function>-<region>-<env>` | `acme-sp-shared-ingest-usw2-prd` |
| UC IAM role and storage credential | `<prefix>-uc-<zone>-<function>-<region>-<env>` | `acme-uc-shared-ingest-usw2-prd` |
| Data KMS alias (regional, no region token) | `alias/<prefix>-<zone>-<function>-<env>` | `alias/acme-shared-ingest-prd` |

Hyphens are used for AWS objects and workspaces, underscores for Unity Catalog objects.

## What each control maps to

### Account (`live/account`)

| Control | Implementation |
|---|---|
| Default serverless egress: deny all | `databricks_account_network_policy.default` (the reserved `default-policy`, imported) with `RESTRICTED_ACCESS`, no destinations, `ENFORCED` |
| All data access through Unity Catalog | `databricks_disable_legacy_features_setting`: no DBFS root, mounts or Hive metastore on new workspaces |
| Managed-services CMK | `aws_kms_key.managed_services` registered as `databricks_mws_customer_managed_keys` (`MANAGED_SERVICES`); encrypts control-plane data and serverless default storage |
| Hardened key policy | Key admins can manage but not use the key; Databricks gets only `kms:Encrypt` and `kms:Decrypt`, scoped by `aws:PrincipalTag/DatabricksAccountId`; automatic rotation on |
| Key events monitored | EventBridge rule on `DisableKey`, `ScheduleKeyDeletion`, `PutKeyPolicy`, grant and alias changes, sent to an SNS topic |

### Per workspace (`modules/serverless-workspace`)

| Control | Implementation |
|---|---|
| Serverless workspace with CMK | `databricks_mws_workspaces` with `compute_mode = "SERVERLESS"`, Enterprise tier, managed-services CMK |
| Egress: only this workspace's buckets | Own network policy with the workspace buckets as the only storage destinations; `egress_enforcement_mode` for dry run, then enforced |
| Private connectivity to S3 | NCC with an S3 private endpoint rule for the workspace buckets |
| Bucket policy pinned to the private endpoint, not IP ranges | `DenyOutsidePrivateEndpoint`: only the NCC VPC endpoint or the Databricks control-plane VPCs, once `s3_private_endpoint_enabled = true` |
| Block governance bypass | `DenyDataAccessOutsideUnityCatalog`: object reads and writes denied to every principal except the UC role and the listed producers, admins included |
| Producers write only to `landing/` | `DenyProducersOutsideLanding` for `landing_writer_principal_arns` |
| Encryption in transit | `DenyInsecureTransport` |
| UC role trust | Trusts the Databricks UCMasterRole with the storage credential's ExternalId, plus the self-assume Unity Catalog requires |
| Path-scoped UC role | Inline policy limited to this workspace's buckets and data key; no SQS/SNS (Auto Loader uses directory listing) |
| Catalogs and locations isolated per environment | Catalogs, external locations and the storage credential are `ISOLATED` and bound to this workspace only |
| UC data-access administration locked down | Storage credential and external locations owned by `uc_admin_group_name`; with `manage_metastore`, only that group may create them |
| Durable records on customer S3 | Versioned buckets with Object Lock (GOVERNANCE, `object_lock_retention_days`), SSE-KMS with a per-workspace key, ACLs disabled, public access blocked |
| Default catalog on customer S3 | `databricks_default_namespace_setting` set to the first signal catalog |
| Checkpoints and libraries on customer S3 | `ops.checkpoints` and `ops.libraries` managed volumes in the first catalog |
| Front door | IP allow list (`databricks_ip_access_list`), personal access tokens disabled, DBFS file browser off |
| Verbose audit and system tables | `enableVerboseAuditLogs`; `system.access` enabled (`manage_metastore`); the workload SP can read `system.billing` and `system.access` |
| Security monitoring | Daily Jobs Serverless Python task, run as the workload SP. It checks default storage usage, credential/location/network-policy changes, writes to the workspace catalog, and egress denials. Any finding fails the run, which emails `alert_emails` |
| CloudTrail correlation | A trail recording S3 data events on the workspace buckets, to join with UC credential vending in `system.access.audit` |
| Pinned serverless environment | `serverless_environment_version` on the jobs this module creates |
| Identity | Account groups (synced from the IdP) assigned as workspace ADMIN and USER; one workload service principal per workspace |

### Prod compensating boundary (`lockdown = true`)

| Concern | Implementation |
|---|---|
| No human data grants | A precondition fails the plan if `human_catalog_privileges` is not empty |
| Nothing lands on default storage | The workspace catalog's grants are replaced by `BROWSE` for admins only; the alert job reports any default storage usage |
| No SQL warehouses for people | `databricks_sql_access = false` on the workspace `users` group |
| No data copies | Result downloads, notebook table clipboard and notebook export disabled |
| Changes only through service principals | `RESTRICT_TOKENS_AND_JOB_RUN_AS` on workspace admins; people get `CAN_VIEW` on jobs |

## Prerequisites

Tools:

- Terraform >= 1.9.
- AWS credentials for the target AWS account, with rights to manage IAM, S3, KMS, CloudTrail and EventBridge.

Databricks:

- A Databricks account on the Enterprise tier, in a region with serverless workspaces.
- An account-admin service principal with an OAuth secret (`client_id` and `client_secret`), used by Terraform.
- A Unity Catalog metastore in the region (its ID is an input).
- The Terraform service principal must be a metastore admin, or a member of `uc_admin_group_name`.

Existing resources this code expects (not created here):

- An S3 bucket and key for Terraform state.
- An S3 bucket for CloudTrail logs, whose bucket policy allows CloudTrail to write.
- An SNS topic for key events, whose policy allows `events.amazonaws.com` to publish.
- Account-level groups synced from the identity provider: workspace admins, workspace users, and the Unity Catalog admins.
- CloudTrail management events in the AWS account (for example an organization trail), which the key-event rule relies on.

## Deploy

### 1. Authenticate

```bash
unset DATABRICKS_HOST DATABRICKS_TOKEN      # stale variables override provider config
export DATABRICKS_CLIENT_ID="<sp-client-id>"
export DATABRICKS_CLIENT_SECRET="<sp-client-secret>"
export AWS_PROFILE="<aws-profile>"          # or any other AWS credential source
```

Both Databricks providers (account and workspace) use the same service principal through OAuth M2M.
No browser login or personal access token is needed, which matters because the module disables tokens.

### 2. Account-wide controls (once per Databricks account)

```bash
cd live/account
cp terraform.tfvars.example terraform.tfvars        # fill in
cp backend.hcl.example backend.hcl                  # fill in
terraform init -backend-config=backend.hcl
terraform plan -out=tfplan
terraform apply tfplan
terraform output managed_services_cmk_id            # input for every workspace
```

### 3. Each workspace (own state per workspace)

```bash
cd live/workspace
cp envs/dev.tfvars.example envs/dev.tfvars          # fill in
cp envs/dev.backend.hcl.example envs/dev.backend.hcl
terraform init -reconfigure -backend-config=envs/dev.backend.hcl
terraform plan -var-file=envs/dev.tfvars -out=tfplan
terraform apply tfplan
```

Repeat with `envs/prd.*` for production.
Real `*.tfvars` and `*.backend.hcl` files are git-ignored; only the `.example` files are committed.

`allowed_ip_cidrs` must include the egress IP of wherever Terraform runs.
Otherwise the IP allow list blocks the next apply.

### 4. Roll out the network controls (per workspace)

The S3 private endpoint cannot be enabled when it is created, so roll out in two applies:

1. First apply with `s3_private_endpoint_enabled = false`, and `egress_enforcement_mode = "DRY_RUN"` in dev.
2. Wait until `terraform output workspace` shows `s3_private_endpoint.connection_state = "ESTABLISHED"`.
3. Apply again with `s3_private_endpoint_enabled = true`. This enables the endpoint and pins the bucket policies to it.
4. Test the allowed path (read the bucket from a serverless job) and the denied path (an internet call is dropped and appears in `system.access.outbound_network`).
5. Set `egress_enforcement_mode = "ENFORCED"` and apply.

### 5. Adopt a workspace created outside Terraform

Set `existing_workspace_id` to the workspace's numeric ID before the first apply.
The root has an `import` block that adopts it instead of creating a new one.
Plan first and check that the workspace is not replaced: its name, region and compute mode must match.

## Run and operate

### Deploy the ingestion job

This code does not deploy workloads.
Deploy the Auto Loader job separately (for example with Databricks Asset Bundles) and follow these rules:

- Run as the workspace service principal (`terraform output workspace` → `service_principal`).
- Use a Python file task, not a notebook, so run output holds status and errors, not records.
- Read from `s3://<signal bucket>/landing/` with directory listing (no file events).
- Write tables to the signal catalog, and checkpoints and schemas to the `checkpoints_volume_path` output.
- Install pinned wheels from the `libraries_volume_path` output; there is no internet access for `pip`.
- Pin the serverless environment version.

### Security alert job

The job `<workspace>-security-alerts` runs daily at 06:00 UTC and looks back 24 hours.
A failed run means at least one check returned rows; the run output lists them.
The checks are:

| Check | Source | Fires on |
|---|---|---|
| `default_storage_usage` | `system.billing.usage` | Any `DEFAULT_STORAGE` usage for the workspace |
| `governance_changes` | `system.access.audit` | Create, update or delete of storage credentials, external locations, network policies or NCCs |
| `workspace_catalog_writes` | `system.access.audit` | Tables, schemas, volumes or functions created in the workspace catalog |
| `egress_denials` | `system.access.outbound_network` | Any denied serverless egress |

To run it on demand: open the job in the workspace and click **Run now**, or run `databricks jobs run-now <job-id>` as an admin.

### Common changes

| Change | How |
|---|---|
| Add a signal type to a workspace | Append it to `signals` (for example `["raw", "enriched"]`); keep the first entry unchanged, since it holds the default catalog and the `ops` volumes |
| Give engineers data access in dev | `human_catalog_privileges = { "<group>" = ["USE_CATALOG", "SELECT", ...] }` |
| Add an environment (`qal`, `e2e`) | Copy a tfvars and backend example, change `environment`, keep `manage_metastore = false` |
| Add a producer that writes to `landing/` | Add its role ARN to `landing_writer_principal_arns`; its own IAM policy must also allow `s3:PutObject` and the data key |

### Destroying

- Buckets have Object Lock, so they cannot be deleted until every object version is past retention. This is intended.
- A destroyed workspace's name cannot be reused for about an hour.
- Deleting `databricks_workspace_conf` can fail for some keys; the provider prints a warning and the setting stays.
- The reserved `default-policy` cannot be deleted; remove it from state instead (`terraform state rm`).

## Gaps: not covered by this code

These requirements need configuration or process outside this repository:

1. **Account console sign-in.** SSO with the corporate identity provider and MFA, and the account admin list, are set in the account console.
2. **Product toggles in prod.** Databricks Apps, Lakeflow, interactive notebooks and Delta Sharing have no stable Terraform setting today. Terraform removes their data paths (no data grants, no SQL entitlement, deny-all egress, no downloads), but the toggles must be turned off in the workspace admin settings, and the Delta Sharing scope at the metastore level.
3. **Front-end PrivateLink.** Not confirmed for serverless workspaces; the IP allow list, SSO with MFA and disabled tokens are the compensating controls.
4. **Compliance security profile and enhanced security monitoring.** Not confirmed for serverless workspaces, so they are not enabled. The customer-managed key, deny-all egress and no human data grants compensate.
5. **Security Analysis Tool.** Not deployed; run it quarterly as a posture check (it needs its own egress allowances).
6. **Process controls.** Reviewing dry-run results, verifying the AWS storage boundary quarterly, testing KMS rotation, peer-reviewing code and deploys, and checking job outputs for secrets are human processes.
7. **Workloads.** The ingestion job is not part of this code (see [Deploy the ingestion job](#deploy-the-ingestion-job)).
8. **Metastore, groups and shared AWS resources.** The metastore, IdP groups, state bucket, CloudTrail log bucket and SNS topic must already exist.
9. **Alert delivery.** Alerts are job-failure emails; integrating with a SIEM or paging tool is not included.
10. **Shared NCC.** The naming convention gives one NCC per zone, region and environment, but the module creates one per workspace. When a second workspace joins the same zone and environment, move the NCC to a shared layer so one S3 rule lists every bucket.
11. **Second region.** `us-east-2` is accepted by the naming, but its Databricks control-plane VPC IDs are not filled in (`modules/serverless-workspace/storage.tf`). Without them, control-plane access to the buckets is denied once the private endpoint is enabled.
12. **Ingress network policy.** The newer IP-based ingress rules of account network policies are not used; the workspace IP allow list is the ingress control.
13. **Real-environment testing.** Nothing has been applied yet; see the next section.

## Assumptions to confirm on first apply

1. **Workspace catalog name.** Serverless workspaces get a catalog on default storage named after the workspace with underscores (for example `acme_shared_ingest_usw2_prd`). The prod revoke and the alert check target that name.
2. **Terraform identity.** The service principal running Terraform is an account admin, a metastore admin (or member of `uc_admin_group_name`), and listed in `kms_admin_arns` and `bucket_admin_principal_arns`. Otherwise it locks itself out of the keys, buckets or UC objects it creates.
3. **Workspace permission assignment.** Groups are assigned with `databricks_mws_permission_assignment` after the metastore is attached (identity federation on). Some guidance reports this API as unavailable on federated workspaces; if the apply fails there, remove that resource and assign the groups in the account console.
4. **Bucket ownership.** Buckets use `BucketOwnerEnforced` (ACLs disabled). Unity Catalog storage validation is expected to pass; if it fails on ACL checks, switch to `BucketOwnerPreferred`.
5. **Object Lock and Delta.** GOVERNANCE retention protects object versions while Delta deletes create delete markers, so Delta `VACUUM` keeps working and storage grows until versions expire after `object_lock_retention_days`.
6. **Serverless environment version.** `serverless_environment_version = "4"` must be a version the workspace supports.
7. **System tables.** `system.billing` is enabled by default; `system.access` is enabled by the workspace with `manage_metastore = true`. A metastore admin can grant `USE_CATALOG` on `system` and `SELECT` on its schemas.
8. **Audit action names.** The governance and workspace-catalog checks match `system.access.audit` action names with patterns. Validate them against real events before relying on them.
9. **Producers.** Upstream producers write to `landing/` from their own network, with their own IAM permissions on the bucket and the data key.
10. **Control-plane VPC IDs.** The `us-west-2` Databricks control-plane VPC IDs come from the public Databricks documentation and can change; re-check them before enabling the private endpoint.
11. **Provider versions.** Databricks provider `~> 1.143` and AWS provider `6.x`, which are the versions this code was validated with.

## Tests

```bash
cd modules/serverless-workspace
terraform init -backend=false
terraform test
```

The tests run offline with mocked providers and need no credentials.
They check the naming convention, the dev and prod lockdown differences, that prod rejects human data grants, and input validation.
