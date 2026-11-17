output "managed_services_cmk_id" {
  description = "Pass to every serverless-workspace module as managed_services_cmk_id."
  value       = databricks_mws_customer_managed_keys.managed_services.customer_managed_key_id
}

output "managed_services_key_arn" {
  value = aws_kms_key.managed_services.arn
}
