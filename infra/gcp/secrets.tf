# ---------------------------------------------------------------------------
# Runtime secret injection. Secret VALUES are added by scripts/sync-secret-manager.sh, not by OpenTofu,
# so they never enter the Terraform state. This file creates the containers, the identities, and the grants.
# Pods read secrets through the GKE Secret Manager add-on with Workload Identity: no key, no static Secret in Git.
# ---------------------------------------------------------------------------
locals {
  secret_names = [
    "llm-api-keys",        # model key file: line 1 inference, line 2 metrics
    "argocd-repo-ssh-key", # read-only deploy key private half, for Argo CD
    "llm-inference-key",   # line 1 only: the single key the chat sends to the model
    "llm-metrics-token",   # metrics key only, for the Managed Prometheus scraper
    "librechat-creds-key",
    "librechat-creds-iv",
    "librechat-jwt-secret",
    "librechat-jwt-refresh",
  ]
}

resource "google_secret_manager_secret" "lab" {
  for_each  = toset(local.secret_names)
  secret_id = each.value
  labels    = local.labels

  replication {
    auto {}
  }
}

# Identity for the model workload (reads the model keys only).
resource "google_service_account" "model_secrets" {
  account_id   = "${var.cluster_name}-model-secrets"
  display_name = "model-endpoint: reads llm-api-keys only"
}

resource "google_secret_manager_secret_iam_member" "model_reads_keys" {
  for_each  = toset(["llm-api-keys", "llm-metrics-token"])
  secret_id = google_secret_manager_secret.lab[each.value].id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.model_secrets.email}"
}

# One binding per Kubernetes service account that reads the inference key (least privilege, ADR 0012).
resource "google_service_account_iam_member" "model_wi" {
  for_each           = toset(["model-endpoint", "gemma-chat", "embedding-endpoint", "grounded-chat"])
  service_account_id = google_service_account.model_secrets.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[llm-serving/${each.value}]"
}

# Identity for the chat workload (reads the LibreChat secrets and the model key it uses to call the model).
resource "google_service_account" "chat_secrets" {
  account_id   = "${var.cluster_name}-chat-secrets"
  display_name = "librechat: reads its own secrets and the model key only"
}

resource "google_secret_manager_secret_iam_member" "chat_reads" {
  for_each  = toset(["llm-inference-key", "librechat-creds-key", "librechat-creds-iv", "librechat-jwt-secret", "librechat-jwt-refresh"])
  secret_id = google_secret_manager_secret.lab[each.value].id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.chat_secrets.email}"
}

resource "google_service_account_iam_member" "chat_wi" {
  service_account_id = google_service_account.chat_secrets.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[chat/librechat]"
}

# Identity for Argo CD's repo server: reads the repository credential only.
resource "google_service_account" "argocd_repo" {
  account_id   = "${var.cluster_name}-argocd-repo"
  display_name = "argocd-repo-server: reads the repository key only"
}

resource "google_secret_manager_secret_iam_member" "argocd_reads_repo_key" {
  secret_id = google_secret_manager_secret.lab["argocd-repo-ssh-key"].id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.argocd_repo.email}"
}

resource "google_service_account_iam_member" "argocd_repo_wi" {
  service_account_id = google_service_account.argocd_repo.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[argocd/argocd-repo-server]"
}
