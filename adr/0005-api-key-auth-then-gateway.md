# ADR 0005: Native API-key auth in slice 1, gateway in phase 2

- Status: accepted
- Date: 2026-10-29

## Context

A gateway with OIDC, per-team keys, and quotas is a larger component than one day allows. llama-server can check a bearer key itself. A single shared key is not employee identity and must be labeled as such.

## Decision

- Slice 1: llama-server `--api-key-file`, keys in a Kubernetes Secret created from `.secrets/`. Verified: missing or wrong key returns 401.
- Phase 2: Envoy Gateway (Gateway API) as the only entry point; it validates the identity and enforces per-team keys and quotas. The model Service stays ClusterIP and is reachable only from the gateway namespace.

## Consequences

- One shared key in slice 1 means no per-user attribution. Documented in THREAT_MODEL.md (T1, T3).

## Reversal

Replaced by the phase 2 gateway. Keep the native key check as defense in depth only if the gateway is compromised; decide in phase 2.
