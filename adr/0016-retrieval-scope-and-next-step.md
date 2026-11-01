# ADR 0016: Retrieval is evaluated and deployed; the chat does not yet retrieve; the next step is a grounded-answer service

- Status: accepted (scope). Implementation is the next release.
- Date: 2026-11-01

## Context
The grounding result (ADR 0010) depends on retrieval, but LibreChat has no retrieval step wired to our embedding service. Its own RAG API needs a vector database and file ingestion that we have not built.

## Options
1. LibreChat RAG API with pgvector: most features; heaviest to run (vector database, ingestion pipeline).
2. A small grounded-answer service in front of Gemma: takes a question, embeds it, retrieves top passages from a store, builds a prompt that forbids unsupported claims, and returns the answer with citations; LibreChat calls it as a custom endpoint.
3. Keep the evaluation harness only: honest, but not a product.

## Decision
Option 2 as the next release. It is the smallest component that makes the grounding guarantee enforceable in the request path, and it keeps retrieval logic in one tested place.

## Consequences
Until it ships, the chat must be described as "not grounded in documents". The article and the diagram say so.
