locals {
  labels = {
    lab        = var.lab_label
    managed-by = "opentofu"
    teardown   = "required"
  }
}

# ---------------------------------------------------------------------------
# Network: custom VPC, one subnet, Private Google Access, no Cloud NAT.
# Nodes have no external IP. They reach Artifact Registry and GKE APIs via Private Google Access.
# ---------------------------------------------------------------------------
resource "google_compute_network" "lab" {
  name                    = "${var.cluster_name}-vpc"
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
}

resource "google_compute_subnetwork" "gke" {
  name                     = "${var.cluster_name}-nodes"
  region                   = var.region
  network                  = google_compute_network.lab.id
  ip_cidr_range            = "10.10.0.0/20"
  private_ip_google_access = true

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = "10.20.0.0/16"
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = "10.30.0.0/20"
  }

  # VPC flow logs are off on purpose: they are billed Logging ingestion with no benefit for a lab.
}

# Deny-by-default ingress to nodes from the internet. GKE adds its own rules for control-plane traffic.
resource "google_compute_firewall" "deny_internet_ingress" {
  name      = "${var.cluster_name}-deny-internet-ingress"
  network   = google_compute_network.lab.name
  direction = "INGRESS"
  priority  = 65000

  deny {
    protocol = "all"
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["gke-node"]
}

# ---------------------------------------------------------------------------
# Identity: node service account with least-privilege roles. Pods use Workload Identity, not keys.
# ---------------------------------------------------------------------------
resource "google_service_account" "nodes" {
  account_id   = "${var.cluster_name}-nodes"
  display_name = "GKE node SA for ${var.cluster_name} (least privilege)"
}

resource "google_project_iam_member" "node_roles" {
  for_each = toset([
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/monitoring.viewer",
    "roles/stackdriver.resourceMetadata.writer",
    "roles/artifactregistry.reader",
  ])

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.nodes.email}"
}

# ---------------------------------------------------------------------------
# Artifact Registry: the model image (weights baked in, digest-pinned) lives here.
# ---------------------------------------------------------------------------
resource "google_artifact_registry_repository" "images" {
  location      = var.region
  repository_id = "${var.cluster_name}-images"
  description   = "Digest-pinned model-serving images for ${var.cluster_name}"
  format        = "DOCKER"
  labels        = local.labels

  cleanup_policies {
    id     = "keep-latest-5"
    action = "KEEP"
    most_recent_versions {
      keep_count = 5
    }
  }
}

# ---------------------------------------------------------------------------
# GKE: zonal Standard cluster, Dataplane V2, private nodes, Workload Identity.
# ---------------------------------------------------------------------------
resource "google_container_cluster" "lab" {
  name     = var.cluster_name
  location = var.zone

  # Lab cluster must be deletable by teardown. Production would keep this true.
  deletion_protection = false

  network    = google_compute_network.lab.id
  subnetwork = google_compute_subnetwork.gke.id

  remove_default_node_pool = true
  initial_node_count       = 1

  release_channel {
    channel = "REGULAR"
  }

  networking_mode = "VPC_NATIVE"
  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  # Dataplane V2 is GKE's managed Cilium eBPF dataplane. It enforces NetworkPolicy.
  datapath_provider = "ADVANCED_DATAPATH"

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = "172.16.0.0/28"
  }

  master_authorized_networks_config {
    dynamic "cidr_blocks" {
      for_each = var.authorized_cidrs
      content {
        cidr_block   = cidr_blocks.value
        display_name = "operator-${cidr_blocks.key}"
      }
    }
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  # System logs and metrics only. Workload logs are not shipped, so prompt bodies never reach Cloud Logging.
  logging_config {
    enable_components = ["SYSTEM_COMPONENTS"]
  }

  monitoring_config {
    enable_components = ["SYSTEM_COMPONENTS"]
  }

  # GKE Gateway API (standard channel) provides the front door without a separate ingress controller.
  gateway_api_config {
    channel = "CHANNEL_STANDARD"
  }

  # Secret Manager add-on: pods mount secrets from Secret Manager through the CSI driver (no secret values in etcd).
  secret_manager_config {
    enabled = true
  }

  # Keep the lab quiet: no legacy ABAC, no basic auth, no client certificate.
  enable_legacy_abac          = false
  enable_shielded_nodes       = true
  resource_labels             = local.labels
  enable_intranode_visibility = true

  # HTTP load balancing must stay enabled: GKE's L7 Gateway classes (gke-l7-global-external-managed) depend on it.
  addons_config {
    http_load_balancing {
      disabled = false
    }
    # NodeLocal DNSCache disabled: on this cluster the node-local listener stopped forwarding to kube-dns
    # (EAI_AGAIN from pods on the second node). Pods resolve through kube-dns directly. Incident in docs/runbooks/chat-operations.md.
    dns_cache_config {
      enabled = false
    }
  }

  maintenance_policy {
    recurring_window {
      start_time = "2026-10-30T02:00:00Z"
      end_time   = "2026-10-30T06:00:00Z"
      recurrence = "FREQ=WEEKLY;BYDAY=SA"
    }
  }

  depends_on = [google_project_iam_member.node_roles]
}

# Old inference pool (e2-standard-2) removed 2026-11-02: drained, empty, workloads moved to inference-32g (see docs/HANDOVER.md).

# ---------------------------------------------------------------------------
# Public edge: proxy-only subnet (required by the global external Application LB), reserved
# static IP, Cloud Armor rate limiting, and a Certificate Manager certificate for <ip>.sslip.io.
# ---------------------------------------------------------------------------
resource "google_compute_subnetwork" "proxy_only" {
  name          = "${var.cluster_name}-proxy-only"
  region        = var.region
  network       = google_compute_network.lab.id
  ip_cidr_range = "10.129.0.0/23"
  purpose       = "GLOBAL_MANAGED_PROXY"
  role          = "ACTIVE"
}

resource "google_compute_global_address" "edge" {
  name        = "${var.cluster_name}-edge-ip"
  description = "Reserved static IP for the chat front door"
  labels      = local.labels
}

resource "google_compute_security_policy" "edge" {
  name        = "${var.cluster_name}-edge-armor"
  description = "Per-IP rate limit at the edge. Default allow; abusive clients get 429."

  # Default rule: allow. Priority 2147483647 is the mandatory catch-all.
  rule {
    action   = "allow"
    priority = 2147483647
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
    description = "default allow"
  }

  rule {
    action   = "rate_based_ban"
    priority = 1000
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
    rate_limit_options {
      conform_action = "allow"
      exceed_action  = "deny(429)"
      enforce_on_key = "IP"
      rate_limit_threshold {
        count        = 120
        interval_sec = 60
      }
      ban_duration_sec = 300
      ban_threshold {
        count        = 600
        interval_sec = 300
      }
    }
    description = "120 req/min per client IP; ban 5 min when 600 req per 5 min"
  }
}

locals {
  # sslip.io maps 203-0-113-10.sslip.io to 203.0.113.10 with no DNS setup. Lab-only convenience.
  edge_hostname = "${replace(google_compute_global_address.edge.address, ".", "-")}.sslip.io"
}

resource "google_certificate_manager_certificate" "edge" {
  name        = "${var.cluster_name}-edge-cert"
  description = "Google-managed certificate for the chat front door"
  labels      = local.labels

  managed {
    domains = [local.edge_hostname]
  }
}

resource "google_certificate_manager_certificate_map" "edge" {
  name   = "${var.cluster_name}-edge-certmap"
  labels = local.labels
}

resource "google_certificate_manager_certificate_map_entry" "edge" {
  name         = "${var.cluster_name}-edge-certmap-entry"
  map          = google_certificate_manager_certificate_map.edge.name
  certificates = [google_certificate_manager_certificate.edge.id]
  hostname     = local.edge_hostname
  labels       = local.labels
}

# ---------------------------------------------------------------------------
# Second node pool: 4 vCPU / 32 GiB (e2-highmem-4). Added beside the original pool so workloads can move
# without downtime; the original pool is removed after the drain (see docs/runbooks/gke-operations.md).
# ---------------------------------------------------------------------------
resource "google_container_node_pool" "inference_32g" {
  name     = "inference-32g"
  location = var.zone
  cluster  = google_container_cluster.lab.name

  autoscaling {
    min_node_count = 1
    max_node_count = var.max_nodes
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  upgrade_settings {
    max_surge       = 1
    max_unavailable = 0
  }

  node_config {
    machine_type = "e2-highmem-4"
    image_type   = "COS_CONTAINERD"
    disk_type    = "pd-balanced"
    disk_size_gb = 40
    spot         = false

    service_account = google_service_account.nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    metadata = {
      disable-legacy-endpoints = "true"
    }

    tags   = ["gke-node"]
    labels = local.labels
  }
}
