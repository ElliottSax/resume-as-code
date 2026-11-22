# Production target: Google Cloud Run, sized to stay inside the free tier.
#
# Design choices worth knowing (more in docs/adr/0005-cloud-run-production.md):
#   - Keyless deploys. GitHub Actions authenticates with a short-lived OIDC
#     token through Workload Identity Federation. There is no service account
#     key to leak, rotate or forget about.
#   - Least privilege. The runtime identity has no roles at all, because the
#     app calls no Google APIs. The deployer can push images and update this
#     one service, nothing else.
#   - Cost has a ceiling. Scale to zero when idle, at most two instances,
#     CPU billed only during requests, and an optional budget alert.
#   - Black-box monitoring. An uptime check probes the public URL from
#     several regions, which catches what in-cluster metrics cannot: DNS,
#     TLS and the load balancer.

provider "google" {
  project = var.project_id
  region  = var.region
}

data "google_project" "this" {}

locals {
  labels = {
    app        = "resume-as-code"
    managed-by = "terraform"
  }
  services = [
    "artifactregistry.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "monitoring.googleapis.com",
    "run.googleapis.com",
    "sts.googleapis.com",
  ]
}

resource "google_project_service" "enabled" {
  for_each           = toset(local.services)
  service            = each.value
  disable_on_destroy = false
}

# ---------------------------------------------------------------- images ----

resource "google_artifact_registry_repository" "images" {
  repository_id = "resume"
  location      = var.region
  format        = "DOCKER"
  description   = "Images promoted from GHCR after passing the chaos drill."
  labels        = local.labels

  docker_config {
    immutable_tags = true
  }

  # Storage costs money; old images are only useful for rollbacks.
  cleanup_policy_dry_run = false
  cleanup_policies {
    id     = "keep-recent"
    action = "KEEP"
    most_recent_versions {
      keep_count = 10
    }
  }
  cleanup_policies {
    id     = "delete-older-than-30-days"
    action = "DELETE"
    condition {
      older_than = "2592000s"
    }
  }

  depends_on = [google_project_service.enabled]
}

# ------------------------------------------------------------ identities ----

resource "google_service_account" "runtime" {
  account_id   = "resume-runtime"
  display_name = "resume-as-code runtime"
  description  = "Identity the service runs as. Deliberately has no roles: the app calls no Google APIs."
}

resource "google_service_account" "deployer" {
  account_id   = "resume-deployer"
  display_name = "resume-as-code deployer"
  description  = "Used only by GitHub Actions on main, through Workload Identity Federation."
}

resource "google_iam_workload_identity_pool" "github" {
  workload_identity_pool_id = "github-actions"
  display_name              = "GitHub Actions"
  depends_on                = [google_project_service.enabled]
}

resource "google_iam_workload_identity_pool_provider" "github" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-oidc"
  display_name                       = "GitHub OIDC"

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
    "attribute.ref"        = "assertion.ref"
  }

  # Only workflows in this repository, running on main, can exchange a token.
  attribute_condition = "assertion.repository == '${var.github_repository}' && assertion.ref == 'refs/heads/main'"

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

resource "google_service_account_iam_member" "deployer_federation" {
  service_account_id = google_service_account.deployer.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${var.github_repository}"
}

resource "google_artifact_registry_repository_iam_member" "deployer_push" {
  repository = google_artifact_registry_repository.images.name
  location   = google_artifact_registry_repository.images.location
  role       = "roles/artifactregistry.writer"
  member     = google_service_account.deployer.member
}

resource "google_cloud_run_v2_service_iam_member" "deployer_update" {
  name     = google_cloud_run_v2_service.resume.name
  location = google_cloud_run_v2_service.resume.location
  role     = "roles/run.developer"
  member   = google_service_account.deployer.member
}

# Deploying a revision that runs as the runtime identity requires actAs on it.
resource "google_service_account_iam_member" "deployer_acts_as_runtime" {
  service_account_id = google_service_account.runtime.name
  role               = "roles/iam.serviceAccountUser"
  member             = google_service_account.deployer.member
}

# --------------------------------------------------------------- service ----

resource "google_cloud_run_v2_service" "resume" {
  name                = "resume"
  location            = var.region
  ingress             = "INGRESS_TRAFFIC_ALL"
  deletion_protection = false
  labels              = local.labels

  template {
    service_account                  = google_service_account.runtime.email
    max_instance_request_concurrency = 80

    scaling {
      min_instance_count = 0 # scale to zero: an idle resume costs nothing
      max_instance_count = 2 # a hard ceiling on spend, whatever the traffic
    }

    containers {
      image = var.image

      ports {
        container_port = 8080
      }

      resources {
        limits = {
          cpu    = "1"
          memory = "256Mi"
        }
        cpu_idle          = true # CPU is billed only while a request is in flight
        startup_cpu_boost = true
      }

      startup_probe {
        period_seconds    = 1
        failure_threshold = 10
        http_get {
          path = "/healthz"
        }
      }

      liveness_probe {
        period_seconds = 10
        http_get {
          path = "/healthz"
        }
      }
    }
  }

  lifecycle {
    # The pipeline ships new images; Terraform owns the service's shape.
    ignore_changes = [template[0].containers[0].image, client, client_version]
  }

  depends_on = [google_project_service.enabled]
}

# It is a public website.
resource "google_cloud_run_v2_service_iam_member" "public" {
  name     = google_cloud_run_v2_service.resume.name
  location = google_cloud_run_v2_service.resume.location
  role     = "roles/run.invoker"
  member   = "allUsers"
}

# ------------------------------------------------------------ monitoring ----

resource "google_monitoring_uptime_check_config" "resume" {
  display_name = "resume-as-code /healthz"
  period       = "300s"
  timeout      = "10s"

  http_check {
    path         = "/healthz"
    port         = 443
    use_ssl      = true
    validate_ssl = true
  }

  monitored_resource {
    type = "uptime_url"
    labels = {
      project_id = var.project_id
      host       = trimprefix(google_cloud_run_v2_service.resume.uri, "https://")
    }
  }

  depends_on = [google_project_service.enabled]
}

resource "google_monitoring_notification_channel" "email" {
  count        = var.alert_email == "" ? 0 : 1
  display_name = "resume-as-code on-call"
  type         = "email"
  labels = {
    email_address = var.alert_email
  }
}

resource "google_monitoring_alert_policy" "uptime" {
  count        = var.alert_email == "" ? 0 : 1
  display_name = "resume-as-code is unreachable from the internet"
  combiner     = "OR"

  conditions {
    display_name = "Uptime check failing"
    condition_threshold {
      filter          = "resource.type = \"uptime_url\" AND metric.type = \"monitoring.googleapis.com/uptime_check/check_passed\" AND metric.label.check_id = \"${google_monitoring_uptime_check_config.resume.uptime_check_id}\""
      comparison      = "COMPARISON_GT"
      threshold_value = 1
      duration        = "600s"
      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_NEXT_OLDER"
        cross_series_reducer = "REDUCE_COUNT_FALSE"
        group_by_fields      = ["resource.label.host"]
      }
    }
  }

  documentation {
    content   = "Runbook: https://github.com/ElliottSax/resume-as-code/blob/main/docs/runbooks/all-replicas-down.md"
    mime_type = "text/markdown"
  }

  notification_channels = [google_monitoring_notification_channel.email[0].id]
}

# ------------------------------------------------------------------ cost ----

resource "google_billing_budget" "monthly" {
  count           = var.billing_account == "" ? 0 : 1
  billing_account = var.billing_account
  display_name    = "resume-as-code monthly budget"

  budget_filter {
    projects = ["projects/${data.google_project.this.number}"]
  }

  amount {
    specified_amount {
      currency_code = "USD"
      units         = tostring(var.monthly_budget_usd)
    }
  }

  threshold_rules {
    threshold_percent = 0.5
  }
  threshold_rules {
    threshold_percent = 0.9
  }
  threshold_rules {
    threshold_percent = 1.0
  }
}
