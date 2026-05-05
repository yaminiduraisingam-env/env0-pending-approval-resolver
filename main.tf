terraform {
  required_version = ">= 1.0.0"
}

# -----------------------------------------------------------------------------
# This is intentionally a no-op Terraform configuration.
# The actual work is done by the custom flow task defined in env0.yml,
# which runs BEFORE this Terraform apply.
#
# The apply step here does nothing — it simply outputs a status message
# confirming the run completed. All meaningful output (which environments
# were actioned, which deployments were cancelled) is in the custom flow
# task logs above.
# -----------------------------------------------------------------------------

output "status" {
  description = "Confirms the resolver run completed. See custom flow task logs for full action details."
  value       = "Pending Approval Resolver completed. Check the 'Resolve Pending Approvals' task log above for the full summary."
}
