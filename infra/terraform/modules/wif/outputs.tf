output "workload_identity_provider" {
  value       = google_iam_workload_identity_pool_provider.github.name
  description = "Pass to google-github-actions/auth as workload_identity_provider."
}

output "deployer_service_account_email" {
  value       = google_service_account.deployer.email
  description = "Pass to google-github-actions/auth as service_account."
}

output "attribute_condition" {
  value       = google_iam_workload_identity_pool_provider.github.attribute_condition
  description = "Printed so it is reviewable in a plan diff — this is the line that keeps other repositories out."
}
