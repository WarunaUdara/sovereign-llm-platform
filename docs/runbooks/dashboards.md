# Dashboards, alerts, and logs

Project: `llm-k8s-experimental`. Replace the project in the links if you change it.

## 1. Dashboard: "llm-lab: sovereign LLM"
Open: https://console.cloud.google.com/monitoring/dashboards?project=llm-k8s-experimental
Choose **llm-lab: sovereign LLM**.

In-cluster Grafana (same data, provisioned as code):
```bash
kubectl -n observability port-forward svc/grafana 3000:3000   # admin / cat .secrets/grafana-admin
# http://localhost:3000/d/sovereign-llm-model
```

Panels:
- **Model health: scrape up**: `max(up{top_level_controller_name="model-endpoint"})`. 1 is healthy.
- **Requests in flight (peak in window)**: `max_over_time(sum(llamacpp:requests_processing)[$__range:30s])`.
- **Requests deferred (peak in window)**: same shape. Above zero means a request waited for a slot.
- **Tokens generated (selected window)**: `sum(increase(llamacpp:tokens_predicted_total[$__range]))`.
- **Generation rate / Prompt rate**: `sum(rate(...[5m]))`. Zero while idle.
- **Prefill speed and Generation speed**: measured tokens/s per request.
- **Peak slot use (% of 4 slots)**: capacity is 2 replicas x 2 slots (`--parallel 2`).
- **Batching efficiency**: `avg(llamacpp:n_busy_slots_per_decode)`.
- **Queue pressure**: `sum(llamacpp:requests_deferred)` over time.

Why the stat panels use `max_over_time`: a stat panel evaluates an instant query at the right edge of
the time range. After a load test the cluster is idle again, so a plain `sum(...)` reads 0 next to a
graph that visibly peaks. `max_over_time(...[$__range:30s])` reports the peak inside the window instead.

To explore further, use **Metrics Explorer** and type `prometheus.googleapis.com/llamacpp` to see all 15 llama.cpp metrics.

Useful PromQL in Metrics Explorer (switch to PromQL):
```promql
# Average prefill speed over 5 minutes (tokens/s). ~30 on this node.
sum(rate(llamacpp:prompt_tokens_total[5m])) / sum(rate(llamacpp:prompt_seconds_total[5m]))
# Average generation speed (tokens/s)
sum(rate(llamacpp:tokens_predicted_total[5m])) / sum(rate(llamacpp:tokens_predicted_seconds_total[5m]))
```

## 2. Alerts
Open: https://console.cloud.google.com/monitoring/alerting?project=llm-k8s-experimental
- **front door is down**: the public HTTPS uptime check fails for 5 minutes.
- **model metrics target is down**: the scrape of llama-server fails for 5 minutes.
Both send email to the address in `infra/gcp/terraform.tfvars` (`alert_email`).

Uptime checks: https://console.cloud.google.com/monitoring/uptime?project=llm-k8s-experimental

## 3. Logs
- **Model** (llama.cpp request and timing lines, the most useful for latency):
  `kubectl -n llm-serving logs deploy/model-endpoint --tail=200`
  Look for `launch_slot_` (a request started), `prompt eval time` (prefill speed), and `exceeds the available context` (prompt too large).
- **Chat** (LibreChat): `kubectl -n chat logs deploy/librechat --tail=200`
  Look for `error`, `Title`, and `Upstream model error`.
- **Edge (load balancer)**: Cloud Logging, resource type `http_load_balancer`. Workload logs are not shipped to Cloud Logging by design (see ADR 0008); load balancer logs are a separate setting, and are off in this lab.
- **Cloud Logging explorer**: https://console.cloud.google.com/logs/query?project=llm-k8s-experimental

## 4. Cluster view
- Workloads and pods: https://console.cloud.google.com/kubernetes/workload/overview?project=llm-k8s-experimental
- Node CPU and memory: GKE > Clusters > llm-lab > Nodes, or `kubectl top nodes`.

## 5. Quick checks from a terminal
```bash
kubectl -n llm-serving top pod; kubectl top nodes
gcloud monitoring dashboards list --format="value(displayName)"
./scripts/smoke-chat.sh
```
