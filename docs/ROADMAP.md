# Roadmap: what is done, what is next, and what "complete" means

Status is as of the latest commit on `main` (2026-10-29). Each open item has an exit criterion, so
"done" is checkable, not a feeling. Priorities: **P0** blocks trusting the system with real users,
**P1** needed before wider use, **P2** quality and operations, **P3** designed only.

## Done and verified
- Public HTTPS front door with a verified certificate, HTTP-to-HTTPS redirect, Cloud Armor attached.
- Invite-only chat (LibreChat v0.8.8): self-registration returns 403; login issues a session token.
- Plain-chat configuration: first reply of "hi" in about 2 s (was a timeout). See [runbooks/chat-operations.md](runbooks/chat-operations.md) incident 5.
- Model reachable only from the chat namespace; default-deny NetworkPolicy in both namespaces; DNS and metrics allow-lists.
- Digest-pinned images for the model, LibreChat, and MongoDB; model hash checked at build.
- Managed Prometheus scrape with a least-privilege token Secret; dashboard, uptime check, two alert policies.
- Teardown script with the chat namespace removed first (dry run tested).

## P0: must close before real users
| Item | Why | Exit criterion |
|---|---|---|
| **Per-user keys and quotas at a gateway** | One shared inference key means no attribution and no per-user limits. The metrics key is also an inference key (ADR 0008). | Each user or team has a scoped key; a request from one user is attributed and rate-limited; the chat UI never holds the model key. |
| **Identity provider (SSO)** | Local passwords do not scale and are the enumeration target (T4). | Sign-in through an OIDC provider; no local password for employees; MFA enforced at the provider. Owner decision H7. |
| **Real teardown with evidence** | The lab spends trial credit until it's gone. | Teardown run, inventory sweep shows zero, evidence saved. |
| **Spend read and recorded** | Budget alerts only notify. | Billing figure recorded against the estimate in `evidence/cloud-gate.md`. |

## P1: needed for wider use
| Item | Why | Exit criterion |
|---|---|---|
| **Load test (k6) and capacity numbers** | We know the 1-user latency, not the 4-user one. | Time to first token and tokens/s at 1, 2, 4 users, saved in `evidence/`. Tuning changes from INFERENCE.md tested against these numbers. |
| **Backups for MongoDB, with a restore test** | Conversations and accounts live only in one PVC. | Scheduled dump to a bucket with a retention rule; a restore into a scratch namespace succeeds and is documented. |
| **Image signing and admission policy** | Pins protect against tag drift, not against a swapped image in the registry. | cosign signatures on our images; Kyverno (or Binary Authorization) rejects unsigned images in `llm-serving` and `chat`. |
| **Quotas on tokens, not only requests** | One user's long prompts can monopolize both slots (T10). | Per-user token budget per hour, enforced at the gateway; a test shows the 429 path. |
| **LibreChat metrics** | The UI is a black box to monitoring today. | `METRICS_SECRET` set; PodMonitoring scrapes it; a dashboard row for active users and errors. |
| **NodeLocal DNSCache root cause** | Disabled as a workaround (H16). | Either the root cause is found and NodeLocal re-enabled with a passing test, or the workaround is accepted in writing. |

## P2: quality and operations
| Item | Why | Exit criterion |
|---|---|---|
| Cloud Armor load test | The rate limit is configured, not measured (H17). | A burst produces 429s from the edge and the backend stays healthy. |
| High availability for the chat layer | One LibreChat replica means a restart is an outage. | Two replicas with `USE_REDIS_STREAMS` and no scheduler conflicts; a pod kill causes no user-visible error beyond a retry. |
| Autoscaling | Node pool scales; the model does not, and CPU replicas on one node gain nothing. | Decision recorded: scale out only with more nodes and a model replica per node. Document the cost and the trigger (`requests_deferred`). |
| Cold-start measurement | Pod start and first request after a node add. | Time from `kubectl apply` to the first 200 on the public URL, recorded. |
| Kubernetes policy as code | Pod security is set per manifest. | Kyverno or conftest tests in CI for the restricted profile; a failing manifest is caught before deploy. |
| Structured audit trail (metadata only) | No prompt logs by design; no audit at all today (T6). | Who-when-which-model metadata per request, retained 30 days, no bodies. |
| CMEK for Secrets and disks | Google-managed keys by default (T14). | Customer-managed keys in Cloud KMS, with a rotation schedule. |
| Terraform remote state | Local state is a single point of loss. | State in a versioned bucket with locking; the bucket itself in the teardown inventory. |

## P3: designed only (not built, not claimed)
- **GPU inference overlay.** The trial has no GPU quota; a node pool with a GPU and the model image for CUDA would be the next step. Not tested.
- **Multi-region failover and a second cluster.** Out of scope for the lab.
- **Speculative decoding and multi-LoRA.** Not worth it on 2 vCPU; designed for GPU serving.

## Decisions taken in this roadmap
1. **Gateway before scale.** A second model replica without per-user keys only adds capacity for anonymous use. P0 comes first.
2. **Measure before tuning.** Inference flags change only with before-and-after numbers in `docs/INFERENCE.md`.
3. **Notify is not a cap.** Spend is controlled by the teardown deadline and the node maximum, not by the budget alert.
