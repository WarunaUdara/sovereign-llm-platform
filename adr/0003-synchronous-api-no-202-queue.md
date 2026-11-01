# ADR 0003: Synchronous inference API, no 202 queue

- Status: accepted
- Date: 2026-10-29

## Context

Client SDKs (OpenAI, Anthropic) expect a response or an SSE stream on the same request. A `202 Accepted` with a poll URL breaks that contract. A generic queue in front of the model also hides failures.

## Decision

Requests are synchronous. The server either streams tokens, returns a complete response, or returns a documented error (4xx for bad input, 503 with Retry-After when saturated). No request is accepted and then silently dropped.

## Consequences

- Concurrency is limited by `--parallel 2`. Extra requests wait inside llama-server's slot logic or get an error; this behavior is measured in phase 6.
- Client timeouts must exceed model load time when the model is cold.

## Reversal

Only with a new ADR and a client contract that supports async results.
