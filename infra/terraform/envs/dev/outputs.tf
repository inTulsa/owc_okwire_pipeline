output "raw_bucket" { value = module.platform.raw_bucket }
output "enrollment_state_bucket" { value = module.platform.enrollment_state_bucket }
output "datasets" { value = module.platform.datasets }
output "service_accounts" { value = module.platform.service_account_emails }
output "image_repository" { value = module.platform.image_repository }

output "lightcast_job" { value = module.lightcast.job_name }
output "lightcast_schedulers" { value = module.lightcast.scheduler_job_names }
output "lightcast_run_command" { value = module.lightcast.run_command }

output "enrollment_job" { value = module.enrollment.job_name }
output "enrollment_schedulers" { value = module.enrollment.scheduler_job_names }
output "enrollment_run_command" { value = module.enrollment.run_command }

output "dataset_task_counts" {
  value       = { for g, ds in local.group_datasets : g => length(ds) }
  description = "One Cloud Run task per dataset, derived from the .sql files on disk."
}
