output "repository_url" {
  description = "The repository on GitHub."
  value       = github_repository.this.html_url
}

output "pages_url" {
  description = "Where the published resume lives."
  value       = github_repository.this.homepage_url
}
