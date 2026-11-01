# ADR 0015: High availability for the chat and model tiers; the database stays single with a stated recovery objective

- Status: accepted.
- Date: 2026-11-01

## Context
Single replicas are a single point of failure. Two LibreChat replicas need shared stream state (Redis), otherwise the scheduler and resumable streams break across replicas. The model is about 3.3 GB per replica.

## Decision
- LibreChat: 2 replicas, Redis for streams (`USE_REDIS`, `USE_REDIS_STREAMS`), one Redis replica in the chat namespace, PodDisruptionBudget `maxUnavailable: 1`.
- Gemma and embedding: 2 Gemma replicas on the 32 GiB pool when memory allows; embedding stays at 1 (smaller blast radius, cheap to restart).
- MongoDB: single instance on a PVC. Recovery objective: the pod restarts in under a minute, and data is not required to survive (owner decision). When data matters, this becomes a 3-member replica set (ADR to be written then).

## Consequences
Two replicas share the same CPU; a single replica failure degrades throughput, not availability. Anti-affinity prefers separate nodes.

## Verification
Drill: kill one LibreChat replica while a chat stream is running; the stream must resume or fail with a clear error, and the next request must succeed. Recorded in `evidence/`.
