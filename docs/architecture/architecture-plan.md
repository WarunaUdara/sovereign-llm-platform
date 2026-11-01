# Sovereign LLM Serving Lab: Architecture and Delivery Plan

**Status:** proposed experimental platform, designed with production practices; not a production service or an always-free GKE deployment.

## Executive decision

The goal is to prove a small, reproducible, private-by-default model-serving platform: OpenAI and Anthropic-compatible APIs, model lifecycle, autoscaling, security controls, telemetry, and teardown. Keep inference synchronous and use one tiny CPU model for the cloud exercise. Treat GPU scheduling as a documented future overlay, not an assumed free-tier capability.

There is an unavoidable constraint conflict: GKE's free-tier credit only offsets one zonal Standard or Autopilot cluster management fee. It does not pay for worker VMs, load balancers, NAT, storage, logs, or egress. Free-trial projects do not receive GPU quota by default. GKE Standard also needs at least one node for system pods; autoscaling the inference pool to zero does not make the cluster itself node-free. Therefore:

1. **Strict $0 / always-free profile (default):** run a small local `kind` cluster on the 16 GB M4; keep a minimal app stack; test local inference with `llama.cpp`/MLX or CPU vLLM only after measuring memory. Use GCP only for explicitly free-tier eligible resources and verify each quota/limit first. This is cloud-native development, not a GKE deployment.
2. **GCP trial-credit profile (optional, time-boxed):** deploy a single-zone GKE Standard cluster for a scheduled lab window. Expect billable node and networking resources to consume trial credits. No GPU. Keep a project-level billing budget/alerts, enforce a hard time-to-live in automation, and tear down the project when the exercise ends. Never upgrade the billing account if a card charge is unacceptable.
3. **Production profile (future):** real identity provider, private network connectivity, durable audit and model governance, paid multi-zone compute, tested backups, staffed on-call, and explicit SLO/capacity commitments. Do not describe the free-trial profile as production-ready.

A budget alert is not a universal spending cap. Current Google documentation describes spend caps only for selected services; do not rely on one to protect all GCP SKUs. A free-trial credit is a subsidy, not an always-free entitlement.

## Scope and success criteria

### Must prove

- One named, pinned, permissively licensed small instruct model can be served through a documented OpenAI-compatible API. Verify Anthropic Messages compatibility with the exact selected gateway version and official SDK; do not infer it from OpenAI compatibility.
- Authentication, per-client quotas/rate limits, bounded request sizes, and synchronous streaming work end to end.
- An idle model deployment can scale from one replica to zero and wake on a request. Measure model cold start separately from node provisioning. No queue silently drops or accepts work it cannot eventually serve.
- Inference pods have explicit CPU/memory/ephemeral-storage requests and limits, readiness/startup probes, bounded concurrency, and graceful termination.
- A default-deny policy allows only the required paths. No prompt or completion bodies are logged by default.
- A one-command deploy, smoke test, and teardown work from a clean checkout. Teardown is independently verified in cloud inventory/billing views.
- A runbook, threat model, architecture decision records, test evidence, and honest cost/limitation statement accompany the demo.

### Explicitly out of scope for the free profile

HA, regional failover, paid GPU inference, arbitrary employee self-service, persistent conversation history, production data residency guarantees, external SaaS identity/logging, and a claim of zero risk of cloud charges.

## Architecture decisions

| Concern | Decision | Reason / rejected approach |
|---|---|---|
| GKE CNI | Use a GKE-supported dataplane. If using Dataplane V2, use its managed Cilium-based implementation and supported policy/flow visibility. | Do not install upstream Cilium as a replacement CNI or mutate GKE-managed eBPF programs. GKE manages this layer. |
| Service mesh | Omit Istio initially. Use one supported Gateway API implementation or a simple internal Service; add mesh only after a concrete need. | Gateway, API adapter, KEDA, and model already create enough moving parts. A mesh does not provide employee SSO, application auth, or API key management by itself. |
| Ingress | For the cloud lab, prefer a single HTTPS endpoint with a GKE-supported gateway/load balancer and explicit allow-list/IAP where feasible. For local mode, port-forward only. | Avoid creating multiple external load balancers (and cost) via stacked ingress controllers. Do not publish an unauthenticated inference endpoint. |
| API gateway | LiteLLM or a small compatible adapter, pinned by immutable image digest. Verify both API protocols in CI. Keep it separate from the model pod. | Gateway translation and auth are control-plane functions, but requests remain synchronous/SSE. |
| Scale-to-zero | KEDA HTTP add-on is an experiment behind the API gateway only if its routing/interceptor semantics are proven with OpenAI and Anthropic streaming tests. Otherwise start with one replica and demonstrate KEDA Prometheus scaling on a synthetic queue/request metric. | Do not insert a generic queue into a synchronous chat API or return `202 Accepted`; SDKs expect a response stream. The scale-to-zero interceptor becomes a critical dependency and its cold-start timeout must exceed measured node+image+model startup. |
| Node scaling | GKE Cluster Autoscaler scales the inference node pool within a strict maximum. Keep the system pool available. | On Standard, the whole cluster does not autonomously scale to zero; system pods need a node. |
| Inference engine | Start with one tiny CPU model and one runtime. Prefer `llama.cpp` GGUF for a predictable CPU demo; keep a separate vLLM CPU build as an optional comparison. Use a distinct CPU image/build, never assume the CUDA image supports `--device cpu`. | CPU support exists but is platform/build-specific and materially slower. Record throughput and TTFT; don't claim GPU behavior was validated. |
| Model assets | Pin model revision and SHA-256; stage a license-reviewed artifact. In strict local mode keep it on disk. In the GCP lab, private GCS is optional and incurs storage/operations costs; use a read-only identity and explicit cleanup. | Avoid runtime downloads from public model hubs, unpinned model drift, and embedding credentials in images. |
| Infra provisioning | Use a small `Taskfile`/scripts as the root lifecycle. Keep a local `kind` Crossplane management cluster only if proving Crossplane is a core deliverable; otherwise use OpenTofu/gcloud for bootstrap and teardown, with Crossplane as a stretch. | A Crossplane controller cannot reliably delete the cluster it runs inside after losing its API/control plane. External management state and an independent project deletion fallback are required. |
| Model plane | Define a narrow `ModelEndpoint` interface (Helm/Kustomize values at first) that renders Deployment, Service, policy, probes, resources, and scale settings. Add a CRD/controller only after the same contract is used for two runtimes. | Avoid building a premature platform API. Crossplane is not the model inference controller. |
| Observability | Start with kube-state/metrics, gateway and model metrics, short-retention Prometheus, one Grafana dashboard, and structured metadata logs. Add traces only when the request path is stable. | Prometheus + Grafana + Tempo + OTel + Hubble + OpenCost can exceed a small node's memory and cost budget. |
| Cilium / flow visibility | GKE Dataplane V2's managed Cilium implementation plus supported GKE flow visibility if available. Use Kubernetes NetworkPolicy for isolation. | Hubble/upstream Cilium controls may not be available on managed GKE dataplane; validate current supported product features before promising Hubble UI. |
| Secrets and identity | No static key in Git or container. Use Workload Identity Federation/Workload Identity on GKE where possible; local credentials remain developer-local. Gateway keys are generated, rotated, and stored as Kubernetes Secrets only for the lab. | A single human API key is not an employee SSO design. Production needs an IdP and audit ownership. |

## Logical request path

1. User/client sends a bounded request using an OpenAI or Anthropic SDK over TLS.
2. Gateway authenticates, applies rate and token/concurrency limits, validates model allow-list, and strips sensitive headers.
3. API adapter normalizes protocol and routes only to the selected `ModelEndpoint`.
4. In scale-to-zero mode, the KEDA HTTP interceptor observes and holds an eligible request while KEDA scales the model pod. The gateway/interceptor timeouts and SSE idle timeouts are configured from measured cold-start percentiles plus margin.
5. Scheduler places the pod on the inference pool. If no node has enough allocatable CPU/RAM, Cluster Autoscaler may add a bounded node. Image/model download, probe readiness, and token generation are separate timing spans.
6. Model streams response tokens back through the same path. On timeout/cancel/disconnect, propagate cancellation and free the inference slot.
7. Emit request ID, model/version, status, input/output token counts, queue wait, TTFT, total latency, and error class. Never log prompt/completion content by default.

## Failure cases and mitigations

| Failure | User impact / detection | Mitigation and acceptance test |
|---|---|---|
| Free-trial GPU quota is zero or zone has no GPU capacity | GPU node creation fails | No GPU dependency in must-have path. GPU overlay is labeled untested; verify quota and region before any future exercise. |
| Credits exhausted, trial expires, or billing account state changes | APIs/resources stop or billing risk changes | Strict profile remains local. For optional GCP run: fixed TTL, spend notification, daily check, project teardown before expiry, never upgrade. Confirm current project billing status. |
| GKE/VM quota exhausted or machine unavailable | Nodes stay Pending; scale-up stalls | Preflight quota/region; cap replicas/nodes; show clear 503/Retry-After; alert on pending duration. |
| System pool consumes expected budget while inference is zero | Idle costs continue | Treat as a hard GKE profile cost; shutdown/delete cluster after each lab, not just scale workload to zero. |
| KEDA interceptor unavailable or max wait too short | Requests hang/fail during cold start | 2 replicas only if resources allow; readiness probes; request deadline; fail fast with 503/Retry-After; fallback mode with min replica 1. Test interceptor restart and end-to-end SSE. |
| KEDA HTTP add-on doesn't preserve protocol/stream semantics | Broken SDK responses or lost streaming | Protocol conformance tests against exact versions. Do not deploy it as the only route until both SDKs pass cold/warm/disconnect tests. |
| Pod scheduled but model cannot fit in memory | OOM loop, repeated cold starts | Load-test model and max context on target node; include KV cache and runtime overhead; set memory request/limit and max context; reject oversized input. |
| Node scaled but image/model download is slow or rate-limited | Cold-start SLO missed | Pin and mirror image; stage model artifact; use checksums; readiness only after model loaded; measure image pull and model load separately. |
| Stream timeout / client disconnect / proxy buffering | Truncated generations, wasted tokens | End-to-end streaming test through every proxy; align gateway, interceptor, load balancer, and SDK timeouts; propagate cancellation. |
| LiteLLM DB/config persistence dependency fails | Authentication/model map unavailable | Keep lab config small; document backing state. If database-backed keys are used, database becomes a required service; add backup/recovery test or use a simpler lab config. |
| Public ingress is unauthenticated or directly exposes model Service | Unauthorized inference/cost/data leak | Only gateway is reachable externally; model Service ClusterIP; auth required; deny-by-default network policy; external scan smoke test. |
| Overbroad model logs or telemetry | Prompt/data disclosure | Body logging disabled; metadata allow-list; short retention; redact keys; test logs with sentinel prompt and verify absence. |
| Mac sleeps / local kind cluster dies while Crossplane owns cloud resources | Orphaned billable resources | Use labels, external inventory and independent `gcloud` cleanup script; test cleanup with management cluster stopped. Never rely solely on the controller. |
| `task down` leaves load balancers, disks, buckets, IPs, or cluster | Continued charges | Delete ingress/LB first; delete model/platform objects; delete infra claims; wait for finalizers; enumerate project resources by labels; project deletion is final fallback. |
| Multi-arch mismatch (M4 arm64 vs GKE amd64) | `exec format error` | Build/publish amd64 or multi-arch image; test manifest architecture and digest before deploy. |
| Spot node preemption during streaming | Connection terminates | Do not require Spot in must-have profile. If tested, treat interruption as expected and measure retry behavior; no automatic replay of non-idempotent requests. |
| Prompt injection / malicious content | Model produces unsafe output or tool misuse | No tools/function execution in first release; model output is untrusted; enforce client-side policy and output handling. This is a model-risk test, not solved by network policy. |

## Security and privacy baseline

- Threat model assets: model weights/license, employee prompts/responses, gateway keys, cloud identities, build pipeline, telemetry, and billable quota.
- Trust boundaries: client to edge, edge to gateway, gateway to model namespace, CI to registry, Crossplane/provider to GCP API, and developer Mac to cloud API.
- Cloud nodes private where the chosen ingress/management path supports it; restrict control-plane access. Keep the model service internal and use default-deny ingress/egress policies with explicit DNS, gateway, telemetry, and model-asset exceptions.
- Use non-root containers, read-only root filesystem where supported, seccomp RuntimeDefault, no privilege escalation, dropped capabilities, Pod Security restricted, resource limits, and image digest pinning.
- CI: secret scan, dependency/image scan, SBOM, license check, and signed image provenance as stretch. Promotion must pin a digest and model hash.
- No employee/production data in this experiment. Use synthetic prompts. Define retention and deletion before any real-user pilot.
- Sovereignty claim is limited to the chosen hosting region, model artifact provenance, and telemetry configuration. It does not imply legal compliance or that all managed control-plane operations remain in-region.

## Observability, SLIs, and test plan

### Metrics

- API request count/error by route and model; active streams; rejection reason.
- Queue/interceptor wait, KEDA desired/current replicas, pod pending duration, node scale-up duration.
- Model load duration, TTFT, inter-token latency/TPOT, tokens per second, request/context length, concurrency, CPU/RAM, OOM/restarts.
- Cost evidence: node-hours, cluster-hours, load-balancer/IP/storage resources, trial credit changes, and teardown leftovers.

### Example objectives for the lab (not production promises)

- Warm API success ≥ 99% over a short scripted run, excluding deliberate overload tests.
- Warm TTFT p95 under 5 seconds for the selected tiny model and fixed prompt on the recorded test machine.
- Publish cold-start p50/p95 as measured; don't set an unsupported fixed target before collecting data.
- Every accepted request either completes, returns a documented error within its deadline, or is explicitly canceled; no silent loss.
- Teardown leaves no resources with the lab label and no active GKE cluster / external IP / persistent disk.

### Verification sequence

1. Static validation: manifests/schema, image digest/architecture, policy checks, model hash/license recorded.
2. Local smoke: OpenAI and Anthropic official SDK tests (warm, streamed, invalid key, unknown model, oversized context, cancellation).
3. Scale tests: 1→0 idle, request at 0, concurrent burst, max replica reached, no capacity, interceptor restart, node scale-up delay, model startup failure.
4. Security tests: direct model endpoint blocked; unauthenticated ingress blocked; namespace boundary blocked; sentinel prompt absent from logs; secrets absent from repo/image.
5. Resilience tests: kill gateway/interceptor/model pod; force node drain or Spot preemption only in optional profile; verify bounded errors and no stale requests.
6. Cost/lifecycle tests: deploy, record exact active billable resources, idle, teardown, inventory sweep, redeploy from clean state.

## Lifecycle and cost guardrails

### Local default

`task preflight` → `task up-local` → `task test` → capture artifacts → `task down-local`.

### Optional GCP trial lab

`task preflight-gcp` checks billing status, region, quotas, APIs, and current free-trial state; requires an explicit profile flag. `task up-gcp` creates one zonal cluster and bounded nodes. A TTL annotation/time-bomb workflow sends a reminder and shuts down the project at the scheduled end. `task test-gcp` records costs and timings. `task down-gcp` deletes the external endpoint first, then platform workloads and cluster, then sweeps labeled resources. Keep an out-of-band `gcloud` cleanup path that works even if Crossplane or Kubernetes is down.

A GCP budget alert is useful but is not a safety boundary. Avoid Cloud NAT, Cloud SQL, Cloud Logging ingestion, Artifact Registry retention, and long-lived IPs unless each has a written cost reason and teardown owner. Regional external load balancing and egress can dominate a tiny demo. No exact spend estimate is promised until region, SKU, uptime, and traffic are known.

## Delivery phases

| Phase | Deliverable | Exit condition |
|---|---|---|
| 0. Constraints and threat model | ADRs, free-vs-credit profile choice, project policy, model license/hash | Team agrees what “$0” means and acknowledges GKE is not always-free compute. |
| 1. Local runnable slice | `kind`, gateway, one model runtime, API tests, local port-forward | Reproducible end-to-end OpenAI streaming call; Anthropic test result recorded. |
| 2. Platform fundamentals | Namespaces, quotas, policies, resource bounds, metrics, dashboard, runbooks | Direct model access blocked; sentinel prompt absent from logs. |
| 3. Autoscaling experiment | KEDA pod scale-to-zero; optional HTTP add-on only after conformance; separate GKE node pool profile | Cold-start stages and failure responses measured; system-node cost called out. |
| 4. Cloud lab | Time-boxed GKE zonal deployment, identity, endpoint, deploy/teardown | Clean teardown survives a stopped Crossplane management cluster; resource inventory empty. |
| 5. Stretch | Crossplane composition, second runtime/vLLM CPU, managed Cilium flow telemetry, tracing, GPU overlay | Each feature has a specific objective and resource budget; GPU is marked untested until quota-backed run. |
| 6. Portfolio handoff | Architecture diagrams, demo, dashboards, benchmark, cost evidence, incident/postmortem | Fresh checkout deploy/test/teardown succeeds and claims match evidence. |

## Suggested repository layout

```text
infra/                 # local bootstrap, optional GCP profile, Crossplane packages
platform/              # namespaces, policies, gateway, KEDA, observability
models/                 # ModelEndpoint values and runtime-specific overlays
apps/                   # gateway config and small helper services
charts/model-endpoint/  # renders Deployment, Service, policies, probes and scaling
scripts/                # preflight, inventory, TTL, cleanup
runbooks/               # deploy, incident, cost, model update, teardown
adr/                    # dated decision records
load/                   # SDK conformance and streaming tests, k6 scenarios
```

## Evidence and unresolved inputs

Before the optional GCP lab, capture the actual billing account type, free-trial expiry, GPU and CPU quota by region, eligible ingress options, project budget/spend-cap eligibility, and the region's current SKU prices. These vary by account, region, and date. Set the model, gateway release, Kubernetes version, and `ModelEndpoint` API only after a compatibility smoke test.

## Current source checks

These official references were checked on 2026-10-29. Recheck account-specific quotas, regional SKUs, and current documentation immediately before the cloud lab.

- [Google Cloud Free Tier features](https://docs.cloud.google.com/free/docs/free-cloud-features?hl=en): GKE's free-tier credit applies to one Autopilot or zonal Standard cluster charge; compute and networking are excluded.
- [GKE pricing](https://cloud.google.com/kubernetes-engine/pricing): GKE cluster management is charged separately from nodes and related resources.
- [GPU requirements for GKE](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/gpus): Free Trial accounts do not receive GPU quota by default.
- [GKE Dataplane V2](https://docs.cloud.google.com/kubernetes-engine/docs/concepts/dataplane-v2): GKE Dataplane V2 is managed and Cilium-based; custom eBPF programs and unsupported CNI replacement are not an install-your-own-Cilium path.
- [GKE Cluster Autoscaler](https://docs.cloud.google.com/kubernetes-engine/docs/concepts/cluster-autoscaler): autoscaling follows declared min/max and pod resource requests; Standard clusters need a node for system pods and do not automatically scale the whole cluster to zero.
- [Cloud Billing budgets](https://docs.cloud.google.com/billing/docs/how-to/budgets): alerts-only budgets do not automatically cap usage or spending.
- [vLLM CPU installation](https://docs.vllm.ai/en/latest/getting_started/installation/cpu/index.html): CPU is supported with platform-specific build requirements; Apple Silicon/macOS support is experimental.
