# Stack inventory: what is used, what is only adjacent, and what is not here

Honest per-component account. "Used" means it runs in the lab and a command or evidence file shows it. "Adjacent" means a platform feature we depend on but did not install. "Not used" means it is absent, and the reason is given.

## Model serving
| Component | Status | Notes |
|---|---|---|
| **llama.cpp (`llama-server`)** | Used | The inference runtime. **Not vLLM.** Chosen because vLLM's official image targets CUDA GPUs, and this trial has no GPU quota. llama.cpp runs CPU inference predictably (ADR 0002). |
| Qwen2.5-0.5B-Instruct (GGUF Q4_K_M) | Used | Apache-2.0, pinned by commit and SHA-256. Baked into the image. |
| vLLM (CPU or GPU) | Not used | The GPU path is designed only (roadmap P3). vLLM CPU needs its own build and is experimental on this platform. |
| Speculative decoding, LoRA, continuous batching at scale | Not used | Not worth it on 2 vCPU; designed only. |

## Networking and eBPF
| Component | Status | Notes |
|---|---|---|
| **GKE Dataplane V2** | Used (managed) | Google's managed dataplane built on **Cilium and eBPF**. We did not install Cilium ourselves; GKE manages it. This is what enforces NetworkPolicy here. |
| **Hubble** (flow observability) | Not enabled | The cluster has the Dataplane V2 observability settings available, but relay and flow logs are off. Enabling it is a P2 item. |
| **Cilium CRDs** (CiliumNetworkPolicy, L7 policy) | Not used | We use standard Kubernetes NetworkPolicy, which Dataplane V2 enforces. |
| **eBPF programs of our own** | Not used | No custom eBPF. Tetragon/Falco-style runtime security is out of scope on Autopilot-class restrictions and not installed. |
| **GKE Gateway API** (global external Application Load Balancer) | Used | Google's managed proxy, configured through the Kubernetes Gateway API. **Not Envoy Gateway, not Istio, not an Envoy we run.** |
| Cloud Armor | Used | Per-IP rate limit at the edge. Rules are not tuned or load tested yet. |
| Google Certificate Manager | Used | Managed certificate for the sslip.io hostname. Replaces cert-manager for this edge. |
| **Istio / service mesh** | Not used | No sidecars, no mTLS between services, no L7 authorization policy. Pod-to-pod traffic is plaintext inside the cluster, which is a gap (see below). |
| Envoy Gateway, Ambient mesh, Linkerd | Not used | |

## Identity and access
| Component | Status | Notes |
|---|---|---|
| Workload Identity | Used | Pods that call Google APIs (the metrics frontend) use it. No service account keys in the cluster. |
| LibreChat local accounts (invite-only) | Used | Passwords in MongoDB. No SSO yet (roadmap P0). |
| Keycloak / any IdP | Not used | Owner decision pending (H7). |
| Kubernetes RBAC | Used | Only the collector's narrow Role for one Secret. Namespaces otherwise rely on defaults. |
| Kyverno / OPA Gatekeeper | Not used | Pod security is set per manifest, not enforced by an admission policy engine (roadmap P2). |
| Pod Security Admission (restricted) | Used | Labels on `llm-serving`, `chat`, `observability`. |

## Delivery and infrastructure
| Component | Status | Notes |
|---|---|---|
| OpenTofu | Used | VPC, GKE, Artifact Registry, Cloud Armor, certificates, monitoring, IAM. Local state (a known risk). |
| Kustomize | Used | Base and overlays for every namespace. |
| Helm | Not used | Manifests are plain YAML, which is easier to review for this size. |
| Argo CD / Flux (GitOps) | Not used | Deployments are `kubectl apply -k` from the operator's machine. This is the largest delivery gap (roadmap P1). |
| Crossplane | Not used | OpenTofu does the infrastructure work. |
| Taskfile | Used | Entry points for preflight, cloud up and down, images, deploy, smoke tests. |
| Container registry | Artifact Registry | Every runtime image is mirrored there and pinned by digest. |
| CI pipeline | Not used | No GitHub Actions yet. Checks run locally. |

## Observability
| Component | Status | Notes |
|---|---|---|
| **Google Managed Prometheus** | Used | Collects llama-server metrics (PodMonitoring) into Cloud Monitoring. |
| **Grafana** | Written, not yet deployed | Manifests in `deploy/observability/grafana` (Grafana 13.2.5, distroless). Waiting on the image mirror, then `kubectl apply -k`. Until then the Cloud Monitoring dashboard is the only dashboard. |
| Cloud Monitoring dashboard | Used | "llm-lab: sovereign LLM" defined in OpenTofu. |
| Alerting | Used | Email alert policies: front door down, model scrape down. No on-call rotation. |
| Uptime checks | Used | HTTPS check on the public URL every 5 minutes. |
| Cloud Logging | Partly used | System components only. Workload logs are off on purpose (privacy); this makes debugging harder (ADR 0008). |
| OpenTelemetry (traces) | Not used | No tracing. The request path (edge, LibreChat, model) cannot be followed as one trace. Roadmap P2. |
| Prometheus Operator / self-hosted Prometheus | Not used | We rely on the managed collector. |
| Loki, Tempo, Jaeger | Not used | |
| OpenCost / cost attribution | Not used | Cost is reviewed in the Billing console only. |

## Autoscaling and resilience
| Component | Status | Notes |
|---|---|---|
| Cluster Autoscaler (node pool 1 to 2) | Used | Observed: scaled to 2 nodes when a pod was unschedulable. |
| KEDA | Not used | Model replicas are fixed at 1. Scaling on `requests_deferred` is designed in the roadmap, not built. |
| HorizontalPodAutoscaler | Not used | CPU-bound replicas on one node would not help. |
| PodDisruptionBudgets | Used | `maxUnavailable: 1` on model, LibreChat, MongoDB. |
| Backups (Mongo) | Not used | Conversations live on one PVC. Roadmap P1. |

## Security controls, and what is not covered
- Used: restricted Pod Security, read-only root filesystems, non-root users, dropped capabilities, seccomp, no service account tokens, default-deny NetworkPolicy, digest pins, model hash checks at build, invite-only accounts, Cloud Armor rate limiting, TLS at the edge, least-privilege metrics token.
- Not covered: pod-to-pod encryption (no mTLS), image signatures (no cosign or admission check), secrets encryption with customer keys (CMEK), SSO and MFA, audit logging of who asked what, prompt-injection defenses, penetration testing, compliance.

## Where to read next
- Architecture and failure modes: `docs/architecture/architecture-plan.md`.
- What to build next, with exit criteria: `docs/ROADMAP.md`.
- How the model is served and why the numbers are what they are: `docs/INFERENCE.md`.
- Operating it: `docs/runbooks/` (chat operations, dashboards, GKE operations).
