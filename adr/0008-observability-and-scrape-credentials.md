# ADR 0008: Observability with Managed Prometheus and a dedicated scrape credential

- Status: accepted
- Date: 2026-10-29

## Context

llama-server exposes Prometheus metrics (tokens, requests in flight, deferred requests, prompt rates) on `/metrics`, and it requires the API key. Scraping needs a credential. Two design questions: which system stores metrics, and how the scraper authenticates without holding the inference key.

## Decision

- **Storage and query:** Google Managed Prometheus on GKE (system and workload metrics; collection is managed, not self-hosted). Dashboards and alerts in Cloud Monitoring, defined in OpenTofu (`infra/gcp/observability.tf`).
- **Scrape:** `PodMonitoring` in `llm-serving` with a Bearer token from Secret `llm-metrics-token`.
- **Credential split:** `scripts/create-api-key.sh` writes two keys: line 1 for inference (chat UI), line 2 for metrics (scraper only). llama-server accepts both. The chat namespace only receives line 1.
- **Least privilege:** the managed collector's service account may `get` and `watch` only the metrics Secret, through a Role limited by `resourceNames`.
- **Network:** the model's ingress policy admits the `gmp-system` namespace on TCP 8080 and nothing else.
- **Public health:** an uptime check on the front door, with alerts on uptime failure and on scrape-target down.

## Limits

- The metrics key is still a valid inference key (llama-server has no read-only key type). Least privilege here means "separate and rotatable", not "scrape-only". Fixing that needs a gateway that issues scoped keys (phase 2).
- LibreChat `/metrics` is disabled (`METRICS_SECRET` unset). Its metrics are not collected yet.
- Workload logs are not shipped to Cloud Logging (system components only). Prompt bodies stay out of logs by design. Error diagnosis uses `kubectl logs` and the pod events.

## Verified (2026-10-29)

- `prometheus.googleapis.com/up/gauge` for the model target: 1 after the RBAC fix (0 before it, with secret-watch errors in the collector).
- 15 `llamacpp:*` metric descriptors visible in Cloud Monitoring.
