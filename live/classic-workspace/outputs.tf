output "workspace" {
  value = {
    name                    = module.workspace.workspace_name
    id                      = module.workspace.workspace_id
    url                     = module.workspace.workspace_url
    service_principal       = module.workspace.service_principal_application_id
    catalogs                = module.workspace.catalogs
    buckets                 = module.workspace.buckets
    network_policy          = module.workspace.network_policy_id
    s3_private_endpoint     = module.workspace.s3_private_endpoint
    checkpoints_volume_path = module.workspace.checkpoints_volume_path
    libraries_volume_path   = module.workspace.libraries_volume_path
    vpc_id                  = module.workspace.vpc_id
    cluster_policy_id       = module.workspace.cluster_policy_id
    root_bucket             = module.workspace.root_bucket
  }
}
