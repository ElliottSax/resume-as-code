terraform {
  required_version = ">= 1.9"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.12"
    }
  }

  # Remote state with locking, so two applies can never race. The bucket is
  # supplied at init time:  terraform init -backend-config="bucket=<name>"
  backend "gcs" {
    prefix = "resume-as-code"
  }
}
