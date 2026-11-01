# Inference: what the model server does, what we measured, what to tune next

Runtime: llama.cpp `llama-server` (digest-pinned), Qwen2.5-0.5B-Instruct Q4_K_M, CPU only, on one GKE node
of 2 vCPU and 8 GB (e2-standard-2). Cluster pins are in `deploy/model-endpoint/base/deployment.yaml`.

## Current settings and why

| Flag | Value | Reason |
|---|---|---|
| `--ctx-size` | 8192 (4096 per slot) | 2048 per slot rejected a real chat prompt (5,029 tokens). |
| `--parallel` | 2 | Two requests at once. More slots split the CPU further. |
| `--n-predict` | 512 | Caps output length so one reply cannot hold a slot for minutes. |
| `--cache-ram` | 256 MiB | The default (8 GiB) is larger than the pod's memory limit. |
| `--timeout` | 300 s | Server-side read and write timeout. |
| `--metrics` | on | Scraped by Managed Prometheus with the metrics key. |
| `--no-webui` | on | The UI is LibreChat; the built-in one is not exposed. |

## Measured on the node (from llama-server's own timing lines)

| Quantity | Measured | Source |
|---|---|---|
| Prefill (prompt processing) | about 30 to 33 tokens/s | `prompt eval time` lines, 2026-10-29 |
| Generation | about 13 tokens/s | `eval time` lines, 2026-10-29 |
| Short chat reply end to end (through LibreChat) | about 2 s, 30-token prompt, 40 total tokens | the verified test |
| Prompt that caused the timeout | 5,029 tokens, about 2.5 min of prefill before any output | derived from prefill rate |

The prefill rate sets the worst case. A prompt of N tokens needs about N / 32 seconds before the first token. Keep prompts short, and the first-token time stays in seconds.

## What drives latency here, in order
1. **Prompt size.** Everything the chat app adds to the prompt (system prompt, tool text, history). Fixed in the chat config. Watch the **prompt tokens per second** chart.
2. **Prefill speed.** About 32 tokens/s on 2 vCPU. Fix options: a faster CPU class, or more vCPUs. The node is the limit, not the server.
3. **Generation speed.** About 13 tokens/s. Fine for chat; slower than a GPU by an order of magnitude.
4. **Concurrency.** Two slots share two vCPUs. A second concurrent request roughly halves each one's speed.

## Tuning candidates (not yet measured; test before adopting)
- `--threads 2` explicitly (the default uses all visible CPUs; check that it doesn't oversubscribe).
- `--batch-size` and `--ubatch-size` for prefill throughput. Measure prefill tokens/s before and after.
- `--cache-reuse` / prompt cache reuse for multi-turn chats (the logs already show `selected slot by LCP similarity`, so prefix reuse works; quantify it).
- A smaller quantization (Q4_0) for speed, with a quality check. Q4_K_M is the current, better-quality choice.
- Speculative decoding. Not worth it on 2 vCPU for a 0.5B model.

## How to measure (repeatable)
1. Send N identical prompts through the chat route and read `prompt eval time` and `eval time` from the model logs.
2. Load test with k6 (phase 6 in the roadmap): record time to first token and tokens/s at 1, 2, and 4 concurrent users.
3. Put the numbers in `evidence/` with the commit hash of the settings tested.

## Not claimed
Output quality of a 0.5B model is not evaluated here. Answers are for testing the platform.
