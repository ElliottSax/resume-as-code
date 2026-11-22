variable "owner" {
  description = "GitHub account that owns the repository."
  type        = string
  default     = "ElliottSax"
}

variable "repository" {
  description = "Repository name."
  type        = string
  default     = "resume-as-code"
}

variable "required_checks" {
  description = "CI job names that must pass before anything merges to main (the `name:` of each job in .github/workflows/ci.yml)."
  type        = list(string)
  default = [
    "Go tests and lint",
    "Chart, policies and alerts",
    "Scripts, workflows and Terraform",
    "Build, scan and chaos drill",
  ]
}
