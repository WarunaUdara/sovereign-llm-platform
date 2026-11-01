output "cluster_name" {
  value = google_container_cluster.lab.name
}

output "cluster_location" {
  value = google_container_cluster.lab.location
}

output "image_repository" {
  description = "Artifact Registry path for the model image."
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.images.repository_id}"
}

output "kubectl_command" {
  value = "gcloud container clusters get-credentials ${google_container_cluster.lab.name} --zone ${var.zone} --project ${var.project_id}"
}

output "edge_ip" {
  value = google_compute_global_address.edge.address
}

output "edge_url" {
  value = "https://${local.edge_hostname}"
}

output "edge_certificate_map" {
  value = google_certificate_manager_certificate_map.edge.name
}

output "edge_armor_policy" {
  value = google_compute_security_policy.edge.name
}
