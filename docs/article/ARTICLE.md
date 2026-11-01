# A private LLM chat platform on GKE: the design, the measurements, and what is still not done

*Draft. Every number links to a file in [EVIDENCE.md](EVIDENCE.md). The repository is private; the evidence and diagrams are the public part.*

## Summary

I built a small, private chat platform on Google Kubernetes Engine. An open-weight model (Qwen2.5-0.5B-Instruct, Apache-2.0, served by llama.cpp on CPU) answers through a ChatGPT-style interface (LibreChat, MIT) behind an invite-only public URL. The platform is designed so that no workload holds a long-lived credential, and the cluster is locked down enough that the model cannot reach the internet.

It runs on a 4-vCPU, 32 GiB node pool. There is no GPU. On a CPU node, prefill runs at about 30 tokens per second, and that single number explains most of the latency behaviour below.

What it proves, with evidence:

- A private cluster with default-deny networking enforced by the managed dataplane.
- A public front door with a verified certificate and an authentication gate.
- Two model replicas: killing one causes no failed requests in a 40-second probe.
- A measured streaming load test at 1, 2, and 4 concurrent users, with zero failed requests.
- A supply chain with digest-pinned images and CI that authenticates to Google without any stored key.

What it does not prove: model quality, GPU performance, mTLS, GitOps reconciliation, or runtime secret injection. Section 7 lists each one and why.

## 1. The system

Architecture diagrams are in [docs/architecture/diagrams.md](../architecture/diagrams.md): system context, trust boundaries, network policy topology, the request sequence, identity and secret flow, the delivery pipeline, and the failure view.

Key components:

- **Edge:** GKE Gateway on a global external load balancer, a Google-managed certificate, and a Cloud Armor rate limit.
- **Chat:** LibreChat v0.8.8 and MongoDB 8.0, in a restricted-profile namespace.
- **Model:** llama-server (llama.cpp), two replicas, with the model baked into a digest-pinned image. The build refuses to bake a model whose SHA-256 does not match the lock file.
- **Observability:** Google Managed Prometheus scrapes llama-server; Grafana reads the same data through the managed frontend.
- **Delivery:** GitHub Actions. Secret scan, static checks, and a build job that runs only on `main`.

## 2. Decisions and why

**Why llama.cpp and not vLLM or llm-d.** vLLM is the reference for high-throughput GPU serving: continuous batching and paged attention over a KV cache. Its CPU build exists but is experimental on this platform, and on a 2-vCPU node it would not beat llama.cpp for a 0.5B model. llm-d adds prefill/decode disaggregation and KV-aware routing on top of vLLM, which assumes a GPU fleet. For a CPU-only proof, llama.cpp gives a small footprint, a native OpenAI-compatible server, and a predictable memory profile. The decision record is ADR 0002. The honest limit: at scale on GPUs, vLLM or llm-d is the right tool, and this platform would change its runtime layer, not its edge or identity design.

**Why GKE Gateway and not Envoy or Istio at the edge.** The Gateway API is the Kubernetes-native front door, and on GKE it is backed by Google's managed load balancer. Fewer components to run means fewer things to break at the edge. ADR 0007 records this.

**Why Dataplane V2.** It is GKE's managed dataplane, built on Cilium and eBPF. Network policy is enforced by the platform, not by a component I would have to operate. The egress comparison in the evidence shows the policy working: the model pod cannot reach a Google API, while a pod in another namespace can.

**Why Workload Identity Federation for CI.** GitHub Actions presents its own short-lived OIDC token, and Google issues a short-lived credential in exchange. The trust condition is limited to one repository and the `main` branch. There is no service-account key anywhere, and no GitHub secret. That is "secret zero" solved for the build. It is not yet solved for workloads (see section 7).

**Why the secret values are kept out of Terraform state.** OpenTofu creates the secret containers and the access grants. The values are added separately, from stdin, by a script. The state file never holds them.

## 3. Measured results

### Load test: a concurrency sweep, and the saturation point

Two harnesses, deliberately separate:

1. **k6 sweep** ([load-sweep-20261031T233955Z.txt](../../evidence/load-sweep-20261031T233955Z.txt)), a Job in the `chat` namespace, so requests cross the same network policies a user's request does. Five constant-VU levels, 40 s each, 1 s think time.
2. **True TTFT** ([ttft-stream-20261031T225751Z.txt](../../evidence/ttft-stream-20261031T225751Z.txt)), a standard-library client that reads the first `data:` line of the stream. k6 buffers the response, so its `waiting` timing is time to first **byte**, not first token.

| Users | Requests | Failed | p50 (s) | p95 (s) | max (s) | TTFB p95 (ms) | chunks/s |
|---|---|---|---|---|---|---|---|
| 1 | 15 | 0 | 2.23 | 2.40 | 2.43 | 4 | 11.6 |
| 2 | 25 | 0 | 2.25 | 4.71 | 4.83 | 55 | 21.4 |
| 4 | 37 | 0 | 3.07 | 7.06 | 8.44 | 3,160 | 32.2 |
| 6 | 46 | 0 | 3.54 | 10.90 | 12.73 | 6,434 | 40.2 |
| 8 | 53 | 0 | 3.21 | 14.12 | 15.04 | 9,332 | 45.6 |

True time to first token, same five levels, measured inside the serving pod:

| Users | Requests | TTFT p50 (ms) | TTFT p95 (ms) | Full stream p50 (ms) |
|---|---|---|---|---|
| 1 | 9 | 51 | 291 | 1,384 |
| 2 | 14 | 85 | 117 | 1,919 |
| 4 | 24 | 939 | 1,835 | 2,784 |
| 6 | 18 | 4,827 | 6,355 | 7,514 |
| 8 | 20 | 7,181 | 8,598 | 9,843 |

Figure: [load-window-llamacpp.png](figures/load-window-llamacpp.png).

**The finding: this deployment saturates at four concurrent streams**, which is exactly its capacity of two replicas x two slots (`--parallel 2`). Below that, TTFT is under 100 ms and the queue is empty. At six users a request waits for a slot and TTFT jumps by more than an order of magnitude (85 ms to 4.8 s); at eight users, four requests are queued at the peak and TTFT p95 is 8.6 s. Throughput still rises with concurrency, which is the point: the cluster is not failing, it is queueing, and the user-visible cost is latency.

Reading these numbers honestly:

- The two harnesses disagree on aggregate throughput: k6 keeps climbing to about 45 chunks/s, while the in-pod client peaks at 37 chunks/s at four users. The in-pod client shares the serving pod's CPU and samples 20 s per level, so it is conservative; k6 runs from another pod with 40 s levels. Both agree on where the knee is.
- TTFB and TTFT are different numbers and the gap widens with load: at four users TTFB p95 is 3.2 s while TTFT p95 is 1.8 s, because headers and the first chunk are not sent at the same moment. Citing TTFB as first-token latency would overstate the problem at low load and understate it at high load.
- Zero failed requests at every level. The endpoint degrades by queueing, not by dropping.
- A first attempt through `kubectl port-forward` produced about 30% failures. The tunnel was the cause, not the model: the same requests inside the cluster all succeeded. That is why both harnesses now run inside the cluster.

### Recovery

- **Kill the only model pod:** service back in 16 seconds. My hypothesis was 30 to 60 seconds. I recorded the miss: the model's files were already in the node's page cache. [drill-d1](../../evidence/drill-d1-kill-model-20261029T040524Z.txt).
- **Kill one of two replicas under probe:** 79 successful probes, 0 failed, over 40 seconds. [drill-d1b](../../evidence/drill-d1b-kill-one-replica-20261029T065623Z.txt).

### Smoke suites

- Model: 10 of 10, including the OpenAI and Anthropic shapes, streaming, auth, oversize rejection, a log-privacy canary, and the egress block. [smoke-model](../../evidence/smoke-model-20261031.txt).
- Public front door: 7 of 7, including TLS verification, the HTTP-to-HTTPS redirect, the authentication gate, and closed self-registration. [smoke-chat](../../evidence/smoke-chat-20261031.txt).

## 4. Incidents that taught something

**The reply that timed out (incident 5).** Typing "hi" produced "Request timed out" after minutes. The model log showed a 5,029-token prompt. LibreChat's agent path was wrapping every message in tool and capability text. On a CPU that prefills about 32 tokens per second, that prompt needs about 2.5 minutes before the first output token. The fix was a plain-chat configuration: no tools, no title generation, no calls to an external provider for activity labels. The same message now arrives as 30 tokens and completes in about 1.6 seconds. Lesson: on CPU, the prompt is the latency budget. Runbook: [chat-operations](../runbooks/chat-operations.md).

**Certificates that were not yet serving.** The managed certificate's first authorization ran before the load balancer served the name, and it reported `RESOLVED_TO_NOT_SERVING`. It recovered on retry, about 30 minutes later. Lesson: a managed certificate has a readiness delay; the uptime check should expect it.

**The DNS path through NodeLocal.** Pods on one node could not resolve service names while the NodeLocal DNS cache was enabled. I added the cache addresses to the allow-list and then disabled the cache. The root cause in the cache was not isolated, and the article says so.

**An allowlist that moved.** The control-plane allowlist permits only my addresses, and my public address changed between sessions, first from one `/32` to another. The fix was a list of `/32` entries, reviewed in a plan before each apply. The honest lesson: operator access tied to an ISP address is a fragile control. The right answer is identity-based access (Connect gateway), which I could not register in this session.

**A load test that flooded the endpoint.** The first in-cluster run had no think time and ran 124,809 iterations in minutes. The abort threshold stopped it. The harness now has a one-second think time, and the abort threshold is on.

## 5. Security posture (what is enforced, and where)

- Pod security: the restricted profile on all three namespaces. Non-root, read-only root filesystems, no capabilities, seccomp, no service-account tokens.
- Network: default-deny ingress and egress in each namespace. Explicit allows only, each named in a policy: the load balancer ranges to the chat, the chat to the model, the scraper to the model metrics port, and DNS.
- Edge: TLS terminated with a managed certificate, a per-IP rate limit, and the authentication gate.
- Supply chain: every image pinned by digest; the model's hash checked at build; third-party images mirrored into our registry; CI with no stored keys.
- Secrets: values generated locally and stored under a gitignored directory. Kubernetes Secrets hold them today. The runtime injection path (Secret Manager through the CSI driver) has its grants and identities in place, but the values have not been loaded, so it is not yet in use.

## 6. What I would change next

1. Read the first streamed chunk to measure true time to first token, and report that instead of time to first byte.
2. Put the operator on identity-based access (Connect gateway) and drop the address allowlist.
3. Load the secret values into Secret Manager and wire the CSI mounts; then remove the Kubernetes Secrets that scripts created.
4. Install Argo CD and point it at the repository through a read-only GitHub App, with its key in Secret Manager.
5. Decide mTLS with a test on a throwaway cluster before touching the production one (ADR 0009). The sources conflict on whether Istio ambient works with Dataplane V2, so the test must be run, not assumed.
6. Add a second chat replica behind Redis streams.

## 7. Scope boundaries and what remains open

| Item | Status | Why |
|---|---|---|
| Runtime secret injection (Secret Manager CSI) | Done for the app pods: values loaded, mounted per workload with Workload Identity. Limitation: the GKE-managed driver cannot sync to Kubernetes Secrets on this cluster, so apps read files (see section 5) | none |
| GitOps reconciliation | Argo CD v3.5.6 installed and healthy; Applications defined for all workloads. Repository access (deploy key) is a single owner action, then `scripts/argocd-bootstrap.sh` | owner adds the read-only deploy key (commands in the summary) |
| mTLS between services | Not installed; decision record and gate written | Conflicting evidence on Istio ambient with Dataplane V2; a throwaway cluster is needed to test it |
| Operator access without a fixed address | Allowlist of two `/32` addresses | Connect gateway requires a fleet registration, which was blocked as a security-weakening change |
| True time to first token | Not measured | The harness reads the response only after it completes |
| Model quality beyond grounding | Measured only on a 12-question grounding set with invented facts; not a general quality benchmark | Larger evaluation sets are future work |
| GPU serving | Not run | The trial has no GPU quota |
| Final spend | Read from the billing console at wind-down, not estimated | owner reads the Billing report |

## 8. Reproducing this

The runbooks are in the repository: [gke-operations](../runbooks/gke-operations.md), [chat-operations](../runbooks/chat-operations.md), and [dashboards](../runbooks/dashboards.md). Every evidence file names the command that produced it. The repository is available to reviewers on request; the article does not depend on reading it.


## 9. Update (2026-10-31): the chat model is Gemma

- **Chat model.** Gemma 4 E2B instruct, quantization-aware trained to Q4_0, served by the pinned llama.cpp runtime. License: Apache-2.0 according to the model card (not gated). Pinned by commit and SHA-256. The chat answers real questions: "The capital of France is Paris." Thinking is disabled at the server, because the model otherwise spends its whole token budget reasoning before it answers.
- **Honest cost of the bigger model.** Server timings: about 19 tokens per second for prefill and 8.2 tokens per second for generation. A typical reply takes about 20 seconds end to end. The 0.5B model answered in about 2 seconds. That is the trade-off for grounding and quality, and the article should present it that way.
- **Grounding evaluation** (12 questions, invented facts, scored by key strings and refusal phrases; small sample, one question moves a score by about 8 points):

| Model | Closed book | With retrieval (top-1) |
|---|---|---|
| Qwen2.5-0.5B | 0 of 12, invents answers | 9 of 12 |
| Qwen2.5-1.5B | 0 of 12, invents answers | 11 of 12 |
| Gemma 4 E2B (chat model) | 0 of 12, invents answers | 12 of 12 |

  The finding worth publishing: a small model without a source invents answers every time, so grounding is the mechanism that removes hallucination, and a better generator improves how well it uses the source.
- **Embedding model.** EmbeddingGemma 2 (Q8_0, Apache-2.0) serves retrieval. Verified: 768-dimensional vectors, and the relevant passage scores 0.88 against the query versus 0.55 for an unrelated one. A common mistake is to pick the embedding model as a chat model. It produces no text.
- **Argo CD.** Installed (v3.5.6, every image from our registry, Dex removed because there is no SSO). Applications are defined for every workload, with automated sync, prune, and self-heal. Repository access uses a read-only deploy key whose private half is stored in Secret Manager.
- **Predictive autoscaling** was researched and deliberately dropped from this release. The reason: the sources found were vendor material, and I could not find a measured comparison for CPU inference. The article says so.

### Scope boundaries (stated, not hidden)

- Retrieval is evaluated, and the embedding service is deployed, but LibreChat does not yet call a retrieval step. Chat answers are not grounded by the retrieval pipeline in this release; the grounding result comes from the evaluation harness.
- mTLS between services is not installed. The decision record (ADR 0009) names the gate that must pass first.
- Operator access uses a short list of `/32` addresses, because my address changes between sessions. Identity-based access is the proper fix.
