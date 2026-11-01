# ADR 0010: Chat model is Gemma 4 E2B (instruct, QAT Q4_0); retrieval grounding is mandatory for answers

- Status: accepted. Supersedes the chat-model part of ADR 0002 (Qwen2.5-0.5B).
- Date: 2026-11-01

## Context
The chat must answer from the documents it is given and must not invent facts. The first chat model (Qwen2.5-0.5B) invented answers on every closed-book question in the golden set.

## Measurements (golden set: 12 questions over invented passages, scored by key strings and refusal phrases)
| Model | Closed book | With retrieval (top-1) |
|---|---|---|
| Qwen2.5-0.5B | 0 of 12 | 9 of 12 |
| Qwen2.5-1.5B | 0 of 12 | 11 of 12 |
| Gemma 4 E2B (QAT Q4_0) | 0 of 12 | 12 of 12 |
Evidence: `evidence/eval-*.json`. The sample is small (one question moves a score by about 8 points). Closed-book hallucination is the robust finding.

## Options
1. Keep Qwen2.5-0.5B: fastest (about 2 s replies), weakest grounding.
2. Qwen2.5-1.5B: better grounding, but a smaller margin over Gemma and a less capable base.
3. Gemma 4 E2B QAT: best grounding measured; Apache-2.0 per the model card; about 20 s typical replies on this node (prefill about 19 tokens/s, generation about 8 tokens/s).

## Decision
Gemma 4 E2B QAT Q4_0, pinned by commit and SHA-256, served on the pinned llama.cpp runtime with thinking disabled at the server (`--chat-template-kwargs enable_thinking=false`).

## Consequences
- Latency is the price: about 10x slower than the 0.5B model. We accept it for grounding; we will not claim interactive speed.
- Answers are only trustworthy when retrieval supplies the source. A chat without retrieval must not be presented as factual (see ADR 0015).
- Licence: the model card lists Apache-2.0. Re-check the card before publishing; the Gemma terms are the fallback reading.

## Reversal
Change the lock-file section `gemma`, rebuild the image through `scripts/build-model-image.sh`-style build, re-run the golden set, and update this ADR with the new table.
