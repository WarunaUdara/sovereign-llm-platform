# ADR 0004: Scale-to-zero deferred behind conformance tests

- Status: accepted
- Date: 2026-10-29

## Context

Scale-to-zero needs something to hold a request while a pod starts. The KEDA HTTP add-on does this, but holding a streaming request through a cold start breaks SDK timeouts and proxy idle limits. Cold start is pod scheduling plus image pull plus model load, which can take minutes on a fresh node.

## Decision

- Slice 1 and phase 2 keep one replica, always warm.
- Phase 4 tests scale decisions on a Prometheus metric (KEDA ScaledObject). Scale-to-zero is attempted only after the HTTP path passes SDK streaming tests.
- `--sleep-idle-seconds` in llama-server is a memory-only fallback that unloads the model when idle. The pod stays up, so it's not scale-to-zero.

## Consequences

- Idle cost on the cloud profile is the node, not the model. That is an accepted cost for the cloud run.

## Reversal

Pass the conformance tests in phase 4 and record the results in this file.
