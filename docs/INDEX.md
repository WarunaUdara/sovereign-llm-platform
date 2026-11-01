# How to read this project

Read in this order. Each step takes 5 to 15 minutes, and the whole set gives the full picture.

## 1. What it is (5 min)
- [README](../README.md): the live URL, the components with their pins, what is verified, what is stated as a limit.

## 2. Why it is built this way (30 min)
Architecture decision records, in order. Each one states a context, the decision, the alternatives rejected, and how to reverse it.
- [ADR 0001](../adr/0001-local-first-zero-cost-profile.md): the first, local-only profile (superseded).
- [ADR 0002](../adr/0002-llama-cpp-runtime-and-qwen-model.md): why llama.cpp and not vLLM, and why Qwen.
- [ADR 0003](../adr/0003-synchronous-api-no-202-queue.md): synchronous API, no hidden queue.
- [ADR 0004](../adr/0004-scale-to-zero-deferred.md): why scale-to-zero is deferred.
- [ADR 0005](../adr/0005-api-key-auth-then-gateway.md): auth in stages.
- [ADR 0006](../adr/0006-gke-cloud-first-lab.md): the GKE design: Dataplane V2, private nodes, no NAT.
- [ADR 0007](../adr/0007-librechat-frontend-and-gateway-edge.md): LibreChat and the Gateway edge.
- [ADR 0008](../adr/0008-observability-and-scrape-credentials.md): Managed Prometheus and the split scrape credential.

## 3. What is in the stack, and what is not (15 min)
- [STACK](STACK.md): every component, marked used, adjacent, or not present. Read this to avoid assumptions, for example that vLLM or Istio is present.

## 4. How the system behaves (20 min)
- [Architecture plan](architecture/architecture-plan.md): the request path, the failure table, the verification sequence.
- [INFERENCE](INFERENCE.md): what limits latency (prefill about 32 tokens/s on 2 vCPU), measured numbers, the tuning candidates.
- [THREAT_MODEL](THREAT_MODEL.md): trust boundaries B1 to B8, threats T1 to T18, and which controls are verified.

## 5. How to operate it (as needed)
- [runbooks/dashboards](runbooks/dashboards.md): where the dashboards, alerts, and logs are, and the PromQL to use.
- [runbooks/chat-operations](runbooks/chat-operations.md): routine checks and five incidents, with root causes and evidence.
- [runbooks/gke-operations](runbooks/gke-operations.md): cluster bring-up, teardown, common failures.
- [runbooks/gke-autoscaler-scale-down](runbooks/gke-autoscaler-scale-down.md): why the node will not scale down, and why the PDB is not the reason.

## 6. What comes next (10 min)
- [ROADMAP](ROADMAP.md): done items, then P0 to P3 with exit criteria.
- [HUMAN_INTERVENTIONS](HUMAN_INTERVENTIONS.md): decisions only the owner can make.
- [COST_GUARDRAILS](COST_GUARDRAILS.md) and `evidence/`: cost gate and saved verification runs.

## 7. Sharing it (15 min)
- [article/ARTICLE.md](article/ARTICLE.md): the write-up, with every number mapped to a file in `evidence/`.
- [article/EVIDENCE.md](article/EVIDENCE.md): claim to evidence file, plus what is deliberately not cited.
- [article/DEMO-SCRIPT.md](article/DEMO-SCRIPT.md): the shot-by-shot recording script, commands, and the screenshot manifest.
- [article/VIDEO-SCRIPT.md](article/VIDEO-SCRIPT.md): the narration to read on camera, with every number checked against `evidence/`.

## Where the code is
| Path | What it is |
|---|---|
| `infra/gcp/` | OpenTofu: network, GKE, Artifact Registry, edge, Cloud Armor, certificates, monitoring, identities |
| `deploy/model-endpoint/` | llama-server: base manifests and the GKE overlay (digest-pinned) |
| `deploy/chat/` | LibreChat, MongoDB, plain-chat config, namespace, overlay |
| `deploy/gateway/` | GKE Gateway, HTTPS redirect, Cloud Armor and health-check policies |
| `deploy/network/` | Chat namespace NetworkPolicies |
| `deploy/monitoring/` | PodMonitoring for llama-server and the least-privilege token RBAC |
| `deploy/observability/` | Grafana (dashboards as code) and the Managed Prometheus frontend |
| `images/` | Dockerfile for the model image |
| `models/models.lock.yaml`, `images/images.lock.yaml` | The only source of pinned versions and digests |
| `scripts/` | Preflight, model fetch, image build and mirror, keys and secrets, smoke tests, teardown |
| `evidence/` | Saved verification runs and the cost gate |

## Conventions
- Pins: every image is referenced by digest. Changing one is a commit that updates a lock file.
- Secrets: values live in Secret Manager and reach pods through the CSI driver; the only local copies are under `.secrets/` (gitignored, never printed). No value is committed and none is in Terraform state.
- Commits: small and single-purpose, each with a message that names the change and its evidence.
