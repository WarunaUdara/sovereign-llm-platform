# Sovereign LLM Platform on GKE

A private, cloud-native chat platform that serves an open-weight model to internal users. The model, the chat UI,
the retrieval service, and the monitoring all run in your own Google Cloud project. Deployment is declarative:
Argo CD reconciles every workload from Git, images are pinned by digest, and every credential is read from
Secret Manager at runtime through Workload Identity, so no long-lived key lives in the cluster or in Git.

> This is a reference implementation. It is designed and tested for the scope in [Limits](#limits). It is not a
> managed product and it is not a compliance-certified system.

## What it does

- **Chat UI:** LibreChat v0.8.8 (MIT) behind a public HTTPS front door, invite-only accounts.
- **Chat model:** Gemma 4 E2B instruct, quantization-aware trained to Q4_0, served by llama.cpp. Apache-2.0 per its model card.
- **Grounded answers:** a service that embeds the question, retrieves the best passage, and refuses when the
  passage does not contain the answer.
- **Embeddings:** EmbeddingGemma 2 (Q8_0, Apache-2.0), 768 dimensions.
- **GitOps:** Argo CD v3.5.6 reconciles seven applications from this repository, with automated sync, prune, and self-heal.
- **Observability:** Google Managed Prometheus scrapes the model. Grafana reads it through a read-only frontend.
  Cloud Monitoring holds a dashboard, an uptime check, and alert policies.

## Architecture

```
 Browser ──HTTPS──▶ Global external ALB (GKE Gateway) ◀── Cloud Armor (per-IP rate limit)
                         │  HTTP 3080, Google front-end ranges only
                         ▼
   ┌──────────── GKE zonal Standard, private nodes, Dataplane V2 ────────────┐
   │ ns chat (restricted, default deny)                                      │
   │   LibreChat ×2 ──▶ Redis (streams)        LibreChat ──▶ MongoDB         │
   │   LibreChat ──▶ grounded-chat (default: direct model, see Limits)       │
   │ ns llm-serving (restricted, default deny, no model egress)              │
   │   grounded-chat ──▶ embedding-endpoint     grounded-chat ──▶ gemma-chat │
   │   gemma-chat ×2 (llama.cpp, Gemma 4 E2B)   embedding-endpoint (×1)      │
   │ ns observability ──▶ ns gmp-public (read-only frontend) ──▶ Cloud Monitoring
   │ ns gmp-system (managed collector) scrapes gemma-chat metrics            │
   │ ns argocd (Argo CD, reads this repository over SSH, read-only key)      │
   └─────────────────────────────────────────────────────────────────────────┘
   Secret Manager ──▶ CSI driver ──▶ pod (Workload Identity, one identity per workload)
   Artifact Registry (digest-pinned images) ◀── CI (Workload Identity Federation, main branch only)
```

The diagrams are in [`docs/architecture/`](docs/architecture/). The reasoning behind each choice is in
[`adr/`](adr/): start with ADR 0010 (chat model), 0012 (secret injection), 0013 (operator access), and 0015 (high availability).

## Security controls

| Control | How it is enforced |
|---|---|
| No static cloud keys in CI | A GitHub OIDC token is exchanged for short-lived Google credentials (Workload Identity Federation), restricted to this repository and the `main` branch |
| No secrets in Git or Terraform state | Values live in Secret Manager and are loaded from stdin. Workloads read them through the CSI driver |
| Least privilege per workload | One Google service account and one Workload Identity binding per workload; each reads only the secrets it needs |
| Network default deny | Default-deny ingress and egress in every namespace, with explicit allows only: Google front-end ranges, chat to model, scraper to metrics, DNS |
| No model egress | Model pods have no route to the internet. Verified with a control pod in another namespace |
| Pod hardening | Restricted Pod Security; non-root; read-only root filesystem; all capabilities dropped; seccomp `RuntimeDefault`; no service-account tokens |
| Supply chain | Every runtime image is pinned by sha256 digest. Model files are verified by SHA-256 before they are baked into an image |
| Edge | TLS with a Google-managed certificate; HTTP redirected to HTTPS; Cloud Armor per-IP rate limit |
| Access | Invite-only accounts (self-registration returns 403). Operator access goes through the GKE Connect gateway, which uses your Google identity |

**Instead of mTLS (not installed):** pods do not have workload mutual TLS yet. The controls above limit which
workloads can talk to which, but traffic inside the cluster is not encrypted. The evaluation of Istio ambient mode
and its verification gate are recorded in [ADR 0009](adr/0009-mtls-mesh-selection.md). The gate has not passed.

## Measured results

Every number below comes from a file in [`evidence/`](evidence/).

| Area | Result | Evidence |
|---|---|---|
| Public front door: TLS, HTTP redirect, auth gate, closed registration, UI served | 7 of 7 | `smoke-chat-final-*.txt` |
| Model API: OpenAI and Anthropic request shapes, streaming, limits, log privacy, egress block | 10 of 10 | `smoke-model-20261031.txt` |
| Grounded answers, 12 questions over invented passages (8 answerable, 4 unanswerable) | 12 of 12 | `eval-grounded-service-*-rescored.json` |
| Same model with no retrieval (closed book) | 0 of 12, invents answers | `eval-gemma4e2b-closedbook-*.json` |
| Embedding ranking (cosine similarity) | Relevant passage 0.88, unrelated passage 0.55 | `gate-embedding-20261031.txt` |
| Kill one of two model replicas during 40 s of probes | 79 successful, 0 failed | `drill-d1b-kill-one-replica-*.txt` |
| Kill one of two chat replicas during a live stream | The stream ends with an explicit error; the next request succeeds | `drill-adr0015-kill-chat-replica-*.txt` |
| Kill the only model pod (earlier single-replica run) | Service back in 16 s. The hypothesis was 30 to 60 s and was recorded as wrong | `drill-d1-kill-model-*.txt` |
| In-cluster streaming load, 1, 2 and 4 users | 148 iterations, 0 failed, all checks passed | `load-in-cluster-20261031T053005Z.*` |
| Time to first token, previous 0.5B model, 1 / 2 / 4 / 6 / 8 users (p50) | 51 / 85 / 939 / 4 827 / 7 181 ms | `ttft-stream-20261031T225751Z.txt` |

Throughput of the chat model on this node class, from llama.cpp's own timing lines: prefill about 19 tokens per
second, generation about 8 tokens per second. A typical reply takes about 20 seconds end to end. The 0.5B model
answered in about 2 seconds. The larger model is slower because it grounds answers better.

## Repository layout

| Path | Purpose |
|---|---|
| `infra/gcp/` | OpenTofu: VPC, GKE cluster and node pool, Artifact Registry, edge, Cloud Armor, certificate, monitoring, identities, Secret Manager, CI identity |
| `deploy/` | Kubernetes manifests (Kustomize) for `chat`, `gemma-chat`, `embedding`, `grounded-chat`, `gateway`, `network`, `observability`, `loadtest`, `model-endpoint` |
| `gitops/` | Argo CD applications (app-of-apps), and the vendored Argo CD and KEDA manifests |
| `images/` | Dockerfiles for the model images. `images.lock.yaml` lists every third-party image, mirrored and digest-pinned |
| `models/models.lock.yaml` | Model files: source commit, file name, size, SHA-256 |
| `services/grounded-answer/` | The grounded-answer service (retrieval plus refusal) |
| `eval/` | The golden set and the grounding evaluation harness |
| `load/` | k6 streaming load test, drills, and a TTFT probe |
| `scripts/` | Preflight, model fetch, image mirroring, secret sync, bootstrap, smoke tests, teardown, Connect gateway kubeconfig |
| `adr/` | Architecture decision records |
| `docs/` | Architecture diagrams, runbooks, threat model, testing strategy, inference notes, roadmap |
| `evidence/` | Saved outputs behind every number above |

## Getting started

You need a Google Cloud project with billing enabled, and these tools: `gcloud`, OpenTofu, `kubectl` with the
`gke-gcloud-auth-plugin`, Docker, `gh`, `helm`, and `kustomize`. `k6` is optional, for load tests.

1. **Replace the placeholders.** The public repository uses example values. Change:
   - `chat.example.com`: the hostname you will use. A sslip.io name works without a domain (`<ip>.sslip.io`).
   - `user@example.com` and `you@example.com`: your email.
   - `203.0.113.x` (operator addresses): set `authorized_cidrs` in `infra/gcp/terraform.tfvars`.
   - `WarunaUdara/sovereign-llm-platform`: your repository, in `gitops/apps/*.yaml`.
   - `llm-k8s-experimental` and project number `40427773756`: your project ID and number.
2. **Provision:** `cd infra/gcp && tofu init && tofu plan -out=tfplan && tofu apply tfplan`.
3. **Fetch the pinned models:** `scripts/fetch-model.sh model`, then `embedding`, then `gemma`.
4. **Mirror third-party images:** `scripts/mirror-images.sh`.
5. **Create local keys and push secret values:** `scripts/create-api-key.sh`, `scripts/create-chat-secrets.sh`, then
   `scripts/sync-secret-manager.sh`. Values go over stdin and are never printed.
6. **Connect GitOps:** create a read-only deploy key for your repository, store its private half in Secret Manager as
   `argocd-repo-ssh-key`, then run `scripts/argocd-bootstrap.sh`.
7. **Check it:** `CHAT_HOST=<your-host> scripts/smoke-chat.sh` and `scripts/smoke-test.sh`.
8. **Create a login:** `scripts/create-chat-user.sh <email> "<name>" <username>`. You type the password at the prompt.

Access the cluster with `KUBECONFIG=$(scripts/connect-gateway-config.sh) kubectl get nodes`, which uses your Google identity.

Teardown: `scripts/teardown-gcp.sh --dry-run`, then `scripts/teardown-gcp.sh`. Workloads are removed first so the
load balancer is released.

## Verify the supply chain locally

```bash
scripts/fetch-model.sh gemma                 # re-verifies the SHA-256 in models/models.lock.yaml
gitleaks dir . --config .gitleaks.toml       # secret scan, with two reviewed allowlists
for o in deploy/chat/overlays/gke deploy/model-endpoint/overlays/gke; do
  kubectl kustomize "$o" | grep -E '^\s*image:' | grep -v -E '@sha256:[0-9a-f]{64}\s*$' \
    && echo "UNPINNED in $o" || echo "pinned: $o"
done
```

## Limits

- **Model quality:** the grounding set has 12 questions over invented passages. It shows that retrieval plus refusal
  removes invented answers on that set. It is not a general quality benchmark.
- **Latency:** the grounded chat model is slow on CPU (about 20 seconds for a typical reply). GPU serving is not implemented.
- **Default endpoint:** LibreChat's default endpoint is still the direct model, so answers are grounded only when a user
  selects the grounded endpoint.
- **Single zone:** the cluster is zonal, with one node pool (`e2-highmem-4`, autoscaled). There is no multi-zone failover.
- **Single database:** MongoDB runs as one instance with no backups. This is acceptable for lab data, not for production data.
- **No mTLS** between services yet (see above).
- **Operator access:** the Kubernetes API is reached through the GKE Connect gateway. An IP allowlist remains as a fallback.
- **Hostnames:** sslip.io names are a lab convenience. Production needs a domain you own.
- **Logs:** workload logs are off by design, so there is no prompt audit trail.
- **Not compliance-certified.** Nothing here is a compliance claim.

## Open items

Tracked in [`docs/ROADMAP.md`](docs/ROADMAP.md). The most important:

1. Install mTLS (service mesh) once a verification gate passes.
2. Remove the IP allowlist once the Connect gateway has been proven across more sessions.
3. Reconcile a load sweep whose per-stage failure counters disagree with its check results. It is not cited here.

## Contributing and security

Issues and pull requests are welcome. Before you open a pull request, run the secret scan and the image-pin check above.
Do not commit `.secrets/`, real `*.tfvars`, or `tfstate` files; they are gitignored. To report a security problem,
use a private security advisory on the repository rather than a public issue.

## License

Apache License 2.0. See [LICENSE](LICENSE).

Third-party components keep their own licenses. Check each one before you redistribute a derivative:

- LibreChat, llama.cpp: MIT
- Argo CD: Apache-2.0
- Gemma 4 E2B and EmbeddingGemma 2: Apache-2.0 according to the model cards at the pinned revisions
- Qwen2.5: Apache-2.0 (the retired 0.5B baseline and its results remain in `evidence/`)
- Redis 8.x: check the Redis license terms for the version you deploy. Redis 8 is offered under more than one license.
