variable "project_id" {
  description = "Google Cloud project to deploy into."
  type        = string
}

variable "region" {
  description = "Region for Cloud Run and Artifact Registry. us-central1 is inside the free tier."
  type        = string
  default     = "us-central1"
}

variable "github_repository" {
  description = "owner/name of the only repository allowed to deploy."
  type        = string
  default     = "ElliottSax/resume-as-code"
}

variable "image" {
  description = "Image for the first apply. After that the pipeline deploys new images and Terraform ignores this field."
  type        = string
  default     = "us-docker.pkg.dev/cloudrun/container/hello"
}

variable "alert_email" {
  description = "Where uptime alerts go. Empty disables the alert policy (the uptime check still runs)."
  type        = string
  default     = ""
}

variable "billing_account" {
  description = "Billing account ID for the budget alert, e.g. 000000-000000-000000. Empty skips the budget."
  type        = string
  default     = ""
}

variable "monthly_budget_usd" {
  description = "Monthly budget in US dollars. Alerts fire at 50%, 90% and 100%."
  type        = number
  default     = 5
}
