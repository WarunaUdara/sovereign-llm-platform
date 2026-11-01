# Testing landscape

Each layer has a purpose, a trigger, a cost, and the failure it is meant to catch. A test that cannot fail is not counted. Status: **automated** runs in CI or a script; **manual** needs an operator; **planned** is defined but not built.

## 1. Layers

| Layer | What it proves | Where it runs | Status |
|---|---|---|---|
| Secret scan | No credentials in Git history of the change | CI, every PR and push | automated (gitleaks) |
| Static (OpenTofu fmt, validate; shell syntax) | Infrastructure and scripts are well-formed | CI, every PR | automated |
| Render check | Every overlay renders; no mutable image tags | CI, every PR | automated (`image` must be `@sha256:`) |
| Policy | Pod security, network policy, resource limits, no `latest` | CI (conftest or Kyverno CLI) | planned |
| Manifest schema | Kubernetes API accepts the objects (kubeconform) | CI | planned |
| Build integrity | Model hash verified before the image bakes it in | CI build job and `fetch-model.sh` | automated |
| Smoke (model) | OpenAI and Anthropic shapes, streaming, auth, limits, privacy log check, egress block | `task test:smoke` | automated (10 checks) |
| Smoke (edge) | Public TLS, redirect, auth gate, invite-only | `scripts/smoke-chat.sh` | automated (7 checks) |
| Integration (chat to model) | LibreChat reaches the model with the inference key and gets a reply | manual through the chat route | manual, verified once (2 s reply) |
| Load | Time to first token and throughput at 1, 2, 4 users | k6 streaming scenario | planned |
| Soak | Memory and error rate over 2 hours | k6 | planned |
| Chaos and failure drills | Recovery times and failure behavior under intentional faults | scripts in `load/drills/` | one drill planned for run now (see section 3) |
| SLO and alerting checks | Each alert fires when its condition is met, and only then | drills | planned |

## 2. Scenarios

Scenarios are written as "given / when / then" with a measurable pass criterion.

### Functional
- **F1 Model answers.** Given the model is ready. When a 16-token prompt is sent. Then HTTP 200, a non-empty reply, under 5 s. (smoke)
- **F2 Streaming.** When `stream: true`. Then SSE chunks end with `[DONE]`. (smoke)
- **F3 Oversize prompt.** When the prompt exceeds the slot context. Then 4xx, not a hang. (smoke)
- **F4 Chat end to end.** Through LibreChat's chat route, a message streams back. Pass: reply in under 10 s on a warm model. (manual, verified 2026-10-29)

### Security
- **S1 Unauthenticated access.** Model without key: 401. Chat data without session: 401. (smoke)
- **S2 Invite-only.** Registration without invitation: 403. (smoke)
- **S3 Egress block.** A model pod cannot reach a Google API. (smoke)
- **S4 Log privacy.** A sentinel prompt string does not appear in model logs. (smoke)
- **S5 Secret scan.** A planted fake key in a commit fails CI. (planned: add a canary branch test)
- **S6 Least privilege.** The collector's token can read exactly one Secret. (planned: `kubectl auth can-i` checks)

### Reliability
- **R1 Model pod loss.** Delete the model pod. Pass: service returns in under 60 s; chat shows an error during the gap, not a hang. (drill, section 3)
- **R2 Chat pod loss.** Delete the LibreChat pod. Pass: recovery under 60 s; sessions survive (MongoDB holds them).
- **R3 Database loss.** Delete the MongoDB pod. Pass: LibreChat reports unavailable and recovers when Mongo returns; no data is required to survive (per owner decision).
- **R4 Node loss.** Drain a node. Pass: pods move to the other pool; PDBs respected. (planned, needs approval for node lifecycle)

### Performance
- **P1 Warm latency.** Time to first token for a short prompt. Target: under 3 s.
- **P2 Concurrency.** Two concurrent users. Measure queueing (`requests_deferred`) and per-user tokens per second.
- **P3 Long prompt.** Prefill time at 2k and 4k tokens. Expected from the measured rate of about 32 tokens/s: 60 s and 120 s.

## 3. Intentional breaks and failure drills

Every drill has a hypothesis written before it runs, a measurement, and a result that is recorded even when the hypothesis is wrong.

| Drill | Intentional break | Hypothesis | Measure | Status |
|---|---|---|---|---|
| D1 Kill model pod | `kubectl delete pod` on the model | Service is down for roughly the cold-start time (about 30 to 60 s) | seconds until `/health` returns 200 | run next (see `load/drills/d1-kill-model.sh`) |
| D2 Kill chat pod | Delete the LibreChat pod | Down for about 20 s; sessions survive | seconds to the next 200 on the public URL | planned |
| D3 Break the key | Rotate the model key in the cluster without updating the chat | Chat returns an error; the alert does not fire (gap to close) | error text; alert state | planned |
| D4 Break the policy | Delete `default-deny-all` in `llm-serving` | Egress test (S3) fails, proving the test is sensitive | smoke check result | planned |
| D5 Break the image | Push an image with a wrong model hash | Build fails at the hash check | CI log | planned |
| D6 Break DNS | Scale kube-dns to zero | Chat cannot resolve Mongo or the model; uptime check fails | alert fire time | planned |
| D7 Break metrics | Revoke the metrics token | "model metrics target is down" fires within 10 min | alert time | planned |
| D8 Rate limit | 300 requests per minute from one IP | 429s from the edge after 120; backend stays healthy | count of 429 vs 200 | planned |
| D9 Expired certificate | Not reproducible safely; document the renewal check instead | n/a | certificate expiry date in the dashboard | planned |
| D10 Node drain | Drain a node with PDBs | Pods move; no more than one replica unavailable | time to rescheduled | planned, needs node-lifecycle approval |

## 4. How results are recorded

Each drill writes `evidence/drill-<id>-<timestamp>.txt` containing the hypothesis, the commands, the timeline, and the verdict. A failed hypothesis is not edited away: it becomes a roadmap item.

## 5. What this does not test
- Model quality (answer correctness). Out of scope for a 0.5B model; see the limits in the README.
- Real attacks or penetration testing. Not performed.
- Multi-region failover. Not built.

## 6. Results so far

- **D1 kill model pod (2026-10-29, `evidence/drill-d1-kill-model-20261029T040524Z.txt`).** Hypothesis was 30 to 60 s of unavailability. Measured: the service answered 200 from the chat namespace again 16 s after the delete. The hypothesis was wrong, and the difference is that the model's files were already in the node's page cache from the previous run. A cold node (new VM, empty cache) will be slower; that's a separate drill to write. Also observed: a single `kubectl` command timed out during the drill, so the drill's "before" listing is incomplete. Retry logic belongs in the drill script.
- **D1b kill one of two model replicas (evidence in `evidence/drill-d1b-*`).** Hypothesis: no failed probes. Measured: 79 successful probes, 0 failed, over 40 seconds while one replica was deleted. Verdict: held. This is the first measured fix for the single-replica risk.
