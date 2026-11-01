# Observability as code: notification channel, public uptime check, alert policies, and a dashboard.
# Metrics come from Google Managed Prometheus (llama-server, scraped via PodMonitoring) and Cloud Load Balancing.

variable "alert_email" {
  description = "Where alerts go. The owner's address; change it in terraform.tfvars."
  type        = string
  default     = "you@example.com"
}

resource "google_monitoring_notification_channel" "email" {
  display_name = "${var.cluster_name} alerts (email)"
  type         = "email"
  labels = {
    email_address = var.alert_email
  }
}

resource "google_monitoring_uptime_check_config" "front_door" {
  display_name = "${var.cluster_name} front door (HTTPS)"
  timeout      = "10s"
  period       = "300s"

  http_check {
    path         = "/"
    port         = 443
    use_ssl      = true
    validate_ssl = true
  }

  monitored_resource {
    type = "uptime_url"
    labels = {
      project_id = var.project_id
      host       = local.edge_hostname
    }
  }
}

resource "google_monitoring_alert_policy" "front_door_down" {
  display_name = "${var.cluster_name}: front door is down"
  combiner     = "OR"

  conditions {
    display_name = "uptime check failing"
    condition_threshold {
      filter          = "metric.type=\"monitoring.googleapis.com/uptime_check/check_passed\" AND resource.type=\"uptime_url\" AND metric.labels.check_id=\"${google_monitoring_uptime_check_config.front_door.uptime_check_id}\""
      duration        = "300s"
      comparison      = "COMPARISON_LT"
      threshold_value = 1
      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_FRACTION_TRUE"
        cross_series_reducer = "REDUCE_MEAN"
      }
      trigger {
        count = 1
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.email.id]
  documentation {
    content   = "The public chat URL failed its HTTPS uptime check for 5 minutes. See docs/runbooks/chat-operations.md."
    mime_type = "text/markdown"
  }
}

resource "google_monitoring_alert_policy" "model_scrape_down" {
  display_name = "${var.cluster_name}: model metrics target is down"
  combiner     = "OR"

  conditions {
    display_name = "llama-server scrape up < 1"
    condition_threshold {
      filter          = "metric.type=\"prometheus.googleapis.com/up/gauge\" AND resource.type=\"prometheus_target\" AND metric.labels.top_level_controller_name=\"model-endpoint\""
      duration        = "300s"
      comparison      = "COMPARISON_LT"
      threshold_value = 1
      aggregations {
        alignment_period   = "120s"
        per_series_aligner = "ALIGN_MEAN"
      }
      trigger {
        count = 1
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.email.id]
  documentation {
    content   = "Managed Prometheus cannot scrape llama-server for 5 minutes. Check PodMonitoring status, the metrics token Secret, and the model pod."
    mime_type = "text/markdown"
  }
}

resource "google_monitoring_dashboard" "lab" {
  dashboard_json = jsonencode({
    displayName = "${var.cluster_name}: sovereign LLM"
    gridLayout = {
      columns = 2
      widgets = [
        {
          title = "Generated tokens per second (model)"
          xyChart = {
            dataSets = [{
              timeSeriesQuery = {
                prometheusQuery = "sum(rate(llamacpp:tokens_predicted_total[5m]))"
              }
              plotType = "LINE"
            }]
          }
        },
        {
          title = "Requests in flight and deferred"
          xyChart = {
            dataSets = [
              {
                timeSeriesQuery = { prometheusQuery = "sum(llamacpp:requests_processing)" }
                plotType        = "LINE"
              },
              {
                timeSeriesQuery = { prometheusQuery = "sum(llamacpp:requests_deferred)" }
                plotType        = "LINE"
              },
            ]
          }
        },
        {
          title = "Prompt tokens per second (model)"
          xyChart = {
            dataSets = [{
              timeSeriesQuery = {
                prometheusQuery = "sum(rate(llamacpp:prompt_tokens_total[5m]))"
              }
              plotType = "LINE"
            }]
          }
        },
        {
          title = "Model scrape health (1 = up)"
          xyChart = {
            dataSets = [{
              timeSeriesQuery = {
                prometheusQuery = "max(up{top_level_controller_name=\"model-endpoint\"})"
              }
              plotType = "LINE"
            }]
          }
        },
      ]
    }
  })
}

# ---------------------------------------------------------------------------
# Query path for Grafana: the Managed Prometheus frontend reads Cloud Monitoring on behalf of Grafana.
# Identity is Workload Identity (no keys). The Google service account can read metrics and nothing else.
# ---------------------------------------------------------------------------
resource "google_service_account" "gmp_frontend" {
  account_id   = "${var.cluster_name}-gmp-frontend"
  display_name = "Managed Prometheus frontend (read-only metrics) for ${var.cluster_name}"
}

resource "google_project_iam_member" "gmp_frontend_viewer" {
  project = var.project_id
  role    = "roles/monitoring.viewer"
  member  = "serviceAccount:${google_service_account.gmp_frontend.email}"
}

resource "google_service_account_iam_member" "gmp_frontend_wi" {
  service_account_id = google_service_account.gmp_frontend.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[gmp-public/frontend]"
}
