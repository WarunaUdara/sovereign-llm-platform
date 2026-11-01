variable "project_id" {
  description = "GCP project that owns every resource in this lab. Must be the experimental project, never a production one."
  type        = string
  default     = "llm-k8s-experimental"
}

variable "region" {
  description = "Region for Artifact Registry and the subnet."
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "Zone for the zonal GKE cluster. Zonal avoids the regional control-plane charge in the lab."
  type        = string
  default     = "us-central1-a"
}

variable "cluster_name" {
  description = "GKE cluster name. Also used as the label value for teardown sweeps."
  type        = string
  default     = "llm-lab"
}

variable "node_machine_type" {
  description = "Machine type for the single node pool. e2-standard-2 fits one 1.5 GiB model pod with headroom."
  type        = string
  default     = "e2-standard-2"
}

variable "min_nodes" {
  type    = number
  default = 1
}

variable "max_nodes" {
  description = "Hard ceiling on nodes. Caps spend if the autoscaler reacts to load."
  type        = number
  default     = 2
}

variable "authorized_cidrs" {
  description = "Operator source addresses allowed to reach the Kubernetes API, as /32 entries. Never 0.0.0.0/0. The operator's ISP address changes between sessions, so several entries are normal."
  type        = list(string)

  validation {
    condition     = alltrue([for c in var.authorized_cidrs : c != "0.0.0.0/0" && can(cidrhost(c, 0))])
    error_message = "every authorized_cidrs entry must be a specific CIDR, not 0.0.0.0/0."
  }
}

variable "lab_label" {
  description = "Label applied to every resource so the teardown sweep can find them."
  type        = string
  default     = "sovereign-llm-lab"
}
