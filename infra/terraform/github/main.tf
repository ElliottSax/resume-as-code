# The repository's own settings, as code: branch protection, required checks,
# merge rules and Pages. Changes to how the repo is governed get reviewed
# like any other change instead of being clicked in a settings page.
#
#   export GITHUB_TOKEN=$(gh auth token)
#   terraform init && terraform plan

provider "github" {
  owner = var.owner
}

# The repository and its Pages site were created before this config existed.
# Import blocks adopt them on the first apply instead of creating duplicates.
import {
  to = github_repository.this
  id = var.repository
}

import {
  to = github_repository_pages.this
  id = var.repository
}

# Public on purpose: this repository is a portfolio meant to be read.
#trivy:ignore:GIT-0001
resource "github_repository" "this" {
  name         = var.repository
  description  = "A resume served by the production platform it describes: Go, Kubernetes, Helm, Terraform, SLOs, chaos drills and a signed supply chain."
  homepage_url = "https://${lower(var.owner)}.github.io/${var.repository}/"
  visibility   = "public"
  topics       = ["devops", "sre", "kubernetes", "helm", "terraform", "github-actions", "chaos-engineering", "supply-chain-security", "slo", "resume"]

  has_issues      = true
  has_wiki        = false
  has_projects    = false
  has_discussions = false

  # Squash merges only: one commit per change keeps main's history readable
  # and makes every commit on main a deployable, reverted-as-a-unit change.
  allow_merge_commit     = false
  allow_rebase_merge     = false
  allow_squash_merge     = true
  allow_auto_merge       = true
  delete_branch_on_merge = true

  lifecycle {
    prevent_destroy = true
  }
}

# Pages is published by the delivery workflow, not built from a branch.
resource "github_repository_pages" "this" {
  repository = github_repository.this.name
  build_type = "workflow"
}

resource "github_repository_vulnerability_alerts" "this" {
  repository = github_repository.this.name
  enabled    = true
}

resource "github_repository_ruleset" "main" {
  name        = "protect-main"
  repository  = github_repository.this.name
  target      = "branch"
  enforcement = "active"

  conditions {
    ref_name {
      include = ["~DEFAULT_BRANCH"]
      exclude = []
    }
  }

  # Break-glass: repository admins can bypass in an emergency. Everyone and
  # everything else, Dependabot included, goes through a pull request.
  bypass_actors {
    actor_id    = 5 # the built-in "Repository admin" role
    actor_type  = "RepositoryRole"
    bypass_mode = "always"
  }

  rules {
    deletion                = true
    non_fast_forward        = true
    required_linear_history = true

    pull_request {
      # A solo project: the pipeline is the reviewer. Raise this with a team.
      required_approving_review_count   = 0
      dismiss_stale_reviews_on_push     = true
      required_review_thread_resolution = true
    }

    required_status_checks {
      strict_required_status_checks_policy = true

      dynamic "required_check" {
        for_each = var.required_checks
        content {
          context = required_check.value
        }
      }
    }
  }
}
