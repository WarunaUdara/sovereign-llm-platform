# ADR 0002: llama.cpp runtime and Qwen2.5-0.5B-Instruct model

- Status: runtime accepted. The model part is superseded by ADR 0010 (Gemma 4 E2B chat, EmbeddingGemma 2 for retrieval).
- Date: 2026-10-29

## Context

The brief names vLLM, but vLLM's official container targets CUDA. CPU vLLM needs its own build and is experimental on macOS. The model must be small enough for a 16 GB Mac with a 3.8 GiB Docker VM.

## Decision

- Runtime: `ghcr.io/ggml-org/llama.cpp:server`, pinned by index digest `sha256:8052c13e…e220` (amd64 and arm64). License MIT.
- Model: Qwen2.5-0.5B-Instruct, GGUF Q4_K_M, from the official `Qwen/Qwen2.5-0.5B-Instruct-GGUF` repo at commit `9217f5db…`. License Apache-2.0. Size 491,400,032 bytes. SHA-256 `74a4da8c…d7a9db`.
- vLLM CPU stays as a documented second runtime for a later comparison, behind the same API.

## Alternatives considered

- SmolLM2-135M-Instruct: smaller and Apache-2.0 at the base model, but no official GGUF publisher exists. Using a third-party GGUF adds an unvetted supply-chain party. Open decision H1.
- vLLM CPU on macOS: experimental; not stable enough for a 4-day window.

## Verified facts

- Flags confirmed from the pinned binary: `--api-key-file`, `--metrics`, `--no-webui`, `--parallel`, `--timeout`, `--cache-ram`, `--sleep-idle-seconds`.
- Default `--cache-ram` is 8192 MiB, which exceeds the pod limit. The deployment sets 256 MiB.
- The `/v1/messages` Anthropic-shape endpoint returned 200 in the smoke test.

## Consequences

- Quality of a 0.5B model is low. Answers are for testing the platform, not for judging model quality.
- Throughput numbers are CPU-only and specific to this machine.

## Reversal

Replace the lock file entries, rerun `scripts/fetch-model.sh`, and update the deployment args. Old and new model hashes both recorded here.
