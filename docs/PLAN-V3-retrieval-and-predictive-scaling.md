# Plan v3: retrieval, a stronger generator, and predictive scaling

Written 2026-10-31. Scope: (1) reduce hallucination in chat, (2) add the embedding model, (3) add predictive autoscaling and test it. Long-running steps run in the background and are checked on fixed timers.

## 1. Correction: EmbeddingGemma 2 cannot replace the chat model

EmbeddingGemma 2 maps text, images, video, and audio to a 768-dimensional vector. It produces no text, so it cannot answer a chat message. Using it as the chat model would remove the chat.

The hallucination comes from the generator: a 0.5-billion-parameter model writes plausible text without a source. Two changes address it, and they are separate jobs:

| Problem | Fix | Model |
|---|---|---|
| The generator invents facts | Ground answers in retrieved text and refuse when nothing supports the answer | Stronger generator: Qwen2.5-1.5B-Instruct (Q4_K_M, 1.1 GB, Apache-2.0, official GGUF) |
| The generator has no source material | Retrieval: embed documents, search by similarity, put the top passages in the prompt | Retriever: EmbeddingGemma 2, Q8_0 GGUF (310 MB, Apache-2.0, pinned) |

Acceptance test for hallucination: a golden set of questions whose answers are in a known document set. Score (a) answers that cite a supplied passage, and (b) refusals when the passage does not contain the answer. Compare the 0.5B baseline against the 1.5B generator with retrieval. The measured result, not the model card, decides.

EmbeddingGemma notes that matter for us: use the Q8_0 quantization (float16 gives silent NaN or degraded output); use the task prefixes (`task: search result | query:` for queries, `title: none | text:` for documents); normalize after any Matryoshka truncation.

## 2. Predictive autoscaling: what the sources support

| Approach | What it does | Evidence | Fit here |
|---|---|---|---|
| Reactive HPA on CPU | Scales on CPU use | Vendor blogs argue CPU is a poor signal for LLM serving because the work waits on the model | Poor signal |
| Reactive KEDA on a queue metric | Scales on in-flight or deferred requests | KEDA is the autoscaler used by KAITO and by Red Hat's OpenShift AI for LLM inference | Good, reactive |
| Predictive HPA (Predictive Horizontal Pod Autoscaler project) | Forecasts the replica count and applies it ahead of time | The project says it needs tuning with real data and can be worse than plain HPA if mis-tuned | Possible, needs history we don't have yet |
| Scheduled scaling (KEDA cron trigger) | Sets a replica floor at known busy hours | KEDA scaler, no forecasting | Good for known business hours |
| Forecast with PromQL `predict_linear` | Linear extrapolation of a queue metric, 10 minutes ahead | Built into Prometheus, runs through our managed frontend | Cheap, no extra component |

Decision: a three-trigger KEDA ScaledObject, where KEDA takes the maximum of the triggers.
1. Reactive: in-flight requests per replica.
2. Predictive: `predict_linear` of in-flight requests over the last 15 minutes, 10 minutes ahead.
3. Scheduled floor: two replicas during the configured busy window.

No published benchmark compares predictive and reactive scaling for CPU LLM inference. The article must say so. We measure ourselves: replay the same load shape with reactive-only and with all three triggers, and compare time-to-second-replica and requests deferred.

Node scaling stays reactive (the cluster autoscaler). Predictive node pre-warming is out of scope until the replica test shows that node provisioning, not pod scheduling, is the delay.

## 3. Execution, timers, and token budget

- Long steps run in the background: model download, image mirroring, load tests. Each has a log file and a completion marker.
- Progress checks use fixed intervals, not polling loops. Download: every 20 minutes. Mirror: every 10 minutes. Load test: once at the end.
- Outputs go to files; only the summary lines are read back, so the context stays small.
- Each completed step is a commit with its evidence file.

## 4. Steps and gates

| # | Step | Gate (must pass to continue) |
|---|---|---|
| 1 | Download and verify the embedding GGUF (SHA-256) | File matches the lock file |
| 2 | Confirm the pinned llama.cpp build loads the embedding model and returns 768-dimensional vectors | `/v1/embeddings` returns the expected shape |
| 3 | Mirror KEDA 2.21.0 images; install KEDA | KEDA pods Ready; CRDs present |
| 4 | Add the predictive ScaledObject to the model | `kubectl get hpa` shows KEDA's external metrics |
| 5 | Replay the load shape with reactive-only, then with all triggers | Time-to-second-replica recorded for both |
| 6 | Deploy the embedding endpoint (second llama-server) | Embedding smoke test passes |
| 7 | Evaluate the 1.5B generator and retrieval against the golden set | Hallucination scores recorded for baseline and new |
| 8 | Switch the chat model only if step 7 improves the scores | Decision recorded in an ADR |

## 5. Known limits, stated up front

- A 1.5B model on a 2-vCPU-class node is slower than the 0.5B model. Expect fewer tokens per second. The trade-off goes into the evaluation.
- The embedding model and the generator share the node's CPU. Load testing both together is the real capacity question.
- Predictive scaling needs history. The first days use reactive triggers and the schedule; the forecast is only trusted after the replay test shows it helps.

## 6. Results so far (2026-10-31)

Golden set: 12 questions over 4 invented passages (so no model can answer from memory). Scoring is by key-string match for answerable questions and by refusal phrases for unanswerable ones. The set is small: one question moves a score by about 8 points.

| Run | Answerable correct | Refusals correct | Total |
|---|---|---|---|
| Qwen2.5-0.5B, closed book | 0 of 8 | 0 of 4 | 0 of 12 (invents answers) |
| Qwen2.5-0.5B, retrieval top-1 | 5 of 8 | 4 of 4 | 9 of 12 |
| Qwen2.5-0.5B, retrieval top-2 | 4 of 8 | 4 of 4 | 8 of 12 |
| Qwen2.5-1.5B, closed book | 0 of 8 | 0 of 4 | 0 of 12 |
| Qwen2.5-1.5B, retrieval top-1 | 8 of 8 | 3 of 4 | 11 of 12 |

Findings:
- Retrieval removes invented answers. Closed-book, both models hallucinate on every unanswerable question.
- The 1.5B generator uses retrieved text better (8 of 8 against 5 of 8). It also gives up one refusal.
- Top-2 context was worse than top-1 for the 0.5B model, which shows the context-selection step matters.

Decision: the chat stays on the 0.5B model for now. LibreChat has no retrieval step of its own, and wiring one in (a RAG API, a vector store, and file ingestion) is the next piece of work. Switching the chat model before that would change answers without grounding them.

Not done in this session: the KEDA install (blocked as a cluster-wide change; the vendored manifest is in `gitops/keda/`), and the predictive scaling test that depends on it.
