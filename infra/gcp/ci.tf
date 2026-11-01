# ---------------------------------------------------------------------------
# CI identity ("secret zero" solved): GitHub Actions exchanges its own short-lived OIDC token for Google
# credentials through Workload Identity Federation. No service-account key exists, anywhere.
# Trust is limited to one repository and the main branch.
# ---------------------------------------------------------------------------
variable "github_repository" {
  description = "owner/name of the repository allowed to act as CI for this lab."
  type        = string
  default     = "WarunaUdara/sovereign-llm-platform"
}

resource "google_iam_workload_identity_pool" "github" {
  workload_identity_pool_id = "${var.cluster_name}-github"
  display_name              = "github-actions"
}

resource "google_iam_workload_identity_pool_provider" "github" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github"
  display_name                       = "GitHub OIDC"

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
    "attribute.ref"        = "assertion.ref"
  }

  # Only this repository, only from main. Pull requests get no cloud identity at all.
  attribute_condition = "assertion.repository == '${var.github_repository}' && assertion.ref == 'refs/heads/main'"
}

resource "google_service_account" "ci" {
  account_id   = "${var.cluster_name}-ci"
  display_name = "CI for ${var.cluster_name}: push images, deploy manifests. No key."
}

# Push images only to the lab repository.
resource "google_artifact_registry_repository_iam_member" "ci_push" {
  project    = var.project_id
  location   = var.region
  repository = google_artifact_registry_repository.images.name
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${google_service_account.ci.email}"
}

# Read cluster credentials and apply manifests. Scoped to the cluster's namespaces by RBAC in the cluster, not here.
resource "google_project_iam_member" "ci_gke" {
  project = var.project_id
  role    = "roles/container.developer"
  member  = "serviceAccount:${google_service_account.ci.email}"
}

resource "google_service_account_iam_member" "ci_wif" {
  service_account_id = google_service_account.ci.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${var.github_repository}"
}

output "ci_workload_identity_provider" {
  value = google_iam_workload_identity_pool_provider.github.name
}

output "ci_service_account" {
  value = google_service_account.ci.email
}
