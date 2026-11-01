# Project plan and roadmap

Status as of 2026-10-29. Companion documents: [architecture](architecture/architecture-plan.md),
[cost guardrails](COST_GUARDRAILS.md), [threat model](THREAT_MODEL.md),
[open decisions](HUMAN_INTERVENTIONS.md), [ADRs](../adr/).

## 1. Goal

Serve a small open-weight model to internal users through OpenAI- and Anthropic-compatible APIs,
built the way a production platform would be built: declarative, authenticated, observable,
policy-enforced, and cleanly removable. Every claim in the write-up must trace to a command output
saved in `evidence/`.

## 2. Constraints that shape the plan

| Constraint | Consequence |
|---|---|
| $270 credit left, about 4 days (ends around 2026-11-02; confirm in Billing) | Local-first. No cloud resource is created until the cloud gate in COST_GUARDRAILS.md passes. |
| GCP Free Trial gives no GPU quota | Inference is CPU only. GPU is a designed overlay, marked untested. |
| Free-tier credit covers only one cluster management fee, not nodes, LBs, NAT, or egress | Cloud runs are time-boxed, and cost is measured, not estimated. |
| Mac M4, 16 GB host, Docker VM at 3.8 GiB | One tiny model, `--parallel 2`, `--ctx-size 4096`. Larger models are out of scope for this machine. |
| CNCF-first tooling was requested | Kubernetes, Helm/Kustomize, KEDA, Argo CD, Prometheus, OpenTelemetry, cert-manager, Kyverno, OpenCost, Keycloak, Envoy Gateway (Gateway API), OpenBao, Cilium. llama.cpp (MIT) is the one non-CNCF runtime, chosen for CPU predictability (ADR 0002). |

## 3. What is decided

- **Profiles.** GKE cloud profile is the active lab (ADR 0006). The local kind profile was retired to free RAM. Production profile is documented, not built.
- **Synchronous API.** No `202 Accepted`, no hidden queue. Clients get a response or a documented error (ADR 0003).
- **Auth in slice 1** is llama-server's native API-key check. The gateway (OIDC, per-team keys, quotas) comes in phase 2 (ADR 0005).
- **Scale-to-zero is deferred.** Held HTTP requests during cold start are not in the must-have path (ADR 0004).
- **Model is pinned** by SHA-256 and commit revision in `models/models.lock.yaml`. Runtime image is pinned by index digest.

## 4. Phases

Status key: DONE = verified by a command output in this repo. TODO = not started.

| Phase | Deliverable | Exit condition | Status |
|---|---|---|---|
| 0. Plan and constraints | This plan, ADRs 0001-0005, cost guardrails, threat model | Docs reviewed; open decisions listed | DONE (review pending) |
| 1. Local runnable slice | kind cluster, pinned llama-server, API key, NetworkPolicy, Taskfile | 10 of 10 checks passed locally (2026-10-29). Local profile then retired to free RAM (ADR 0006). | DONE, superseded by phase 5 |
| 2. Gateway and identity | Envoy Gateway (Gateway API) in front of the model; OIDC via Keycloak for employees; per-team keys with hashed storage and budgets | Unauthenticated and wrong-team calls rejected at the gateway; model Service unreachable from outside `llm-serving` | TODO |
| 3. Observability and SLOs | Prometheus (short retention), Grafana dashboard, OpenTelemetry Collector, Pyrra SLOs, burn-rate alerts | Dashboard shows TTFT, tokens/s, queue wait from real load | TODO |
| 4. Autoscaling | KEDA ScaledObject on Prometheus metrics (requests running). Scale-to-zero experiment only if conformance passes. `--sleep-idle-seconds` as a memory-only fallback. | Scale decisions visible; cold-start stages measured | TODO |
| 5. Cloud profile | Zonal GKE Standard, one e2-standard-2 pool (1-2 nodes), Dataplane V2, private nodes, Workload Identity, digest-pinned model image | Cluster RUNNING, model pod Ready, 10 of 10 smoke checks pass on GKE, egress control verified. Real teardown pending. | BUILT (2026-10-29); teardown and spend read pending |
| 6. Load, chaos, evidence | k6 streaming load test (TTFT), kill-pod and bad-config game days, postmortem | Capacity curve and failure reports saved in `evidence/` | TODO |
| 7. Portfolio handoff | README, runbooks, ADRs final, demo recording, teardown log | Fresh clone runs `task up-local` and smoke test passes | TODO |

## 5. Edge cases and how each is handled

Full failure table with acceptance tests is in [architecture-plan.md](architecture/architecture-plan.md).
These are the ones already encoded in code or scripts:

| Case | Where handled | Test |
|---|---|---|
| Model file corrupted or swapped | `scripts/fetch-model.sh` checks size and SHA-256 before use | Hash check runs on every bring-up |
| Model served from a tag that moved | Image pinned by index digest; model pinned by commit SHA | `models.lock.yaml` review |
| Pod pending on a full node | Explicit CPU and memory requests; `maxSurge: 0` avoids two models competing for RAM | Rollout status gate in `deploy:local` |
| Model load slower than probes allow | Startup probe allows 120 s | Cold start measured in phase 4 |
| Oversized prompt exhausts memory | `--ctx-size 4096`, `--n-predict 512`, server rejects oversize | Smoke test: oversize returns 4xx |
| Node drain blocked by PDB | `maxUnavailable: 1`, not `minAvailable: 1` | Reviewed in PDB comment |
| Prompt content lands in logs | Server does not log bodies by default | Sentinel-string log check in smoke test |
| Model pod calls the internet | Default-deny egress NetworkPolicy | Control-pod comparison (verified 2026-10-29) |
| Secrets in Git | `.secrets/` gitignored; keys created locally and never printed | `.gitignore`; key file mode 600 |
| Teardown incomplete | `down-local` removes cluster, key, and render output; cloud teardown is gated | Local teardown only; cloud teardown designed in phase 5 |
| Docker VM too small for kind | Preflight warns below 4 GiB | Observed: 3.8 GiB worked for the single model pod |

## 6. Repository layout

```text
README.md                 entry point and quick start
Taskfile.yml              single lifecycle entry point
docs/                     plan, cost, threat model, decisions, runbooks
docs/architecture/        architecture diagrams and the detailed failure table
adr/                      architecture decision records
infra/gcp/               OpenTofu: VPC, GKE, node pool, Artifact Registry, node SA
images/model-endpoint/    Dockerfile: runtime + model baked in, hash-checked at build
deploy/model-endpoint/    Kustomize base and GKE overlay (digest pinned)
models/                   pinned lock file; weights cache is gitignored
scripts/                  preflight, model fetch, key creation, smoke tests
evidence/                 saved command outputs that back each claim (phase 6-7)
.claude/skills/           agent skills installed from skills.sh (see H8 for review status)
```

## 7. Timeline (4-day window)

| Day | Date | Work |
|---|---|---|
| 1 | 2026-10-29 | Plan, local slice, smoke tests passing (done) |
| 2 | 2026-10-30 | Gateway and identity (phase 2); observability start |
| 3 | 2026-10-31 | Observability and autoscaling experiment (phases 3-4); cloud gate decision |
| 4 | 2026-11-01 | Load and chaos tests, evidence capture; cloud run only if the gate passes; teardown |

Day 4 ends before the trial does. Cloud teardown is done before the last day regardless of progress.

## 8. Definition of done

1. `task up-local` on a clean clone passes the smoke test, with evidence saved.
2. OpenAI SDK and Anthropic SDK calls both succeed (the raw HTTP checks pass today; official SDK tests are phase 2).
3. Unauthenticated access, direct cross-namespace access, and model egress are each shown blocked.
4. A load test reports TTFT and throughput at 1, 4, and 8 concurrent streams.
5. Cloud profile either ran within the gate and was torn down with an empty inventory, or was not run and the docs say so.
6. Every number in the write-up points at a file in `evidence/`.
