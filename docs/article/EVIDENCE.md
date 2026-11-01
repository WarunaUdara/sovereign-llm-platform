# Evidence index

Every number in the article maps to a file here. Files prefixed `TUNNEL-RUN`, `FAILED`, or `teardown` are kept for honesty and are cited only where noted.

| Claim in the article | Evidence file | What it shows |
|---|---|---|
| Model answers through the OpenAI and Anthropic shapes; streaming; auth; limits; log privacy; egress blocked | `smoke-model-20261031.txt` (10 of 10) | Run on 2026-10-31 against both replicas |
| Public front door: TLS, redirect, auth gate, invite-only | `smoke-chat-20261031.txt` (7 of 7) | Run on 2026-10-31 against the public URL |
| In-cluster load: concurrency sweep at 1, 2, 4, 6 and 8 concurrent users | `load-sweep-20261031T233955Z.txt` and `.json` | 176 requests, 0 failed, per-level p50/p95 duration and TTFB, throughput |
| True time to first token per concurrency level (first streamed chunk) | `ttft-stream-20261031T225751Z.txt` | TTFT p50/p95 from inside the serving pod; shows the knee at 4 concurrent streams |
| Generation and queue behaviour under load | `docs/article/figures/load-window-llamacpp.png` | Cloud Monitoring series for the test window |
| Kill one of two replicas: no user-visible failure | `drill-d1b-kill-one-replica-20261029T065623Z.txt` | 79 successful probes, 0 failed over 40 s |
| Kill the only pod (before the second replica): recovery time | `drill-d1-kill-model-20261029T040524Z.txt` | 16 s to first 200; hypothesis (30 to 60 s) was wrong |
| Interactive reply after the agent-prompt fix | Incident 5 in `docs/runbooks/chat-operations.md` | Prompt 5,029 to 30 tokens; reply in about 2 s |
| Cluster settings: Dataplane V2, private nodes, Workload Identity, Shielded nodes, no legacy ABAC | `cluster-state-20261028T213157Z.txt` | Captured from `gcloud` and `kubectl` on 2026-10-28 |
| Egress: policy blocks, control reaches Google APIs | Same cluster-state file, section "egress control comparison" | Model pod times out; control pod in another namespace returns HTTP 404 from the API root |
| Teardown path tested (dry run) | `teardown-20261029T002713Z.log` | Dry run only; the real teardown is not yet run |
| Trial cost gate and budget | `cloud-gate.md` | Gate conditions, estimate, and the notify-only budget |
| Image digests and supply chain | `images/images.lock.yaml`, `models/models.lock.yaml` | Every runtime image pinned by digest |
| CI: secret scan, static checks, WIF build on main | GitHub Actions runs (links in the article, from `gh run list`) | Green runs; no GitHub secrets exist |

## Not cited, and why

- `FAILED-run-20261031T051024Z-tunnel-not-ready.txt`: a load run started before the port-forward listened. It produced no valid measurement.
- `TUNNEL-RUN-unreliable-20261031T051422Z.*`: a valid run through `kubectl port-forward`, with about 30% failures. The tunnel was the cause (every request through it returned `000` while the same requests inside the cluster returned 200). It is evidence for the claim "port-forward is not a load path", not a latency result.
- `load-20261031T...` JSON from the first in-cluster attempt: the Job ran in a namespace that the network policy blocks; the failure is documented in the commit history, not used as data.

## Re-running the evidence

- Smoke: `./scripts/smoke-chat.sh` and `./scripts/smoke-test.sh`.
- Load: `./load/run-in-cluster.sh` (writes a new `load-sweep-*` pair).
- True TTFT: `./load/run-ttft.sh` (writes `ttft-stream-*`; the harness is piped into the serving pod, nothing is installed).
- Figure: `python3 scripts/render-evidence-charts.py <start> <end> docs/article/figures` (uses your gcloud identity; no secret values are printed).
- Drills: `load/drills/d1-kill-model.sh`.

## Added 2026-10-31 (v3)

| Claim | Evidence |
|---|---|
| EmbeddingGemma 2 served by the pinned runtime, 768-dim, correct ranking | `evidence/gate-embedding-20261031.txt` |
| Grounding eval, Gemma 4 E2B (chat model): retrieval 12/12, closed book 0/12 | `evidence/eval-gemma4e2b-retrieval-top1-*.json`, `evidence/eval-gemma4e2b-closedbook-*.json` |
| Grounding eval, Qwen2.5-1.5B and 0.5B baselines | `evidence/eval-qwen1.5b-*.json`, `evidence/eval-qwen0.5b-*.json` |
| Public chat smoke after the Gemma switch: 7 of 7 | `evidence/smoke-chat-gemma-*.txt` |
| In-cluster streaming load (earlier run, 0.5B) | `evidence/load-in-cluster-20261031T053005Z.*` |
