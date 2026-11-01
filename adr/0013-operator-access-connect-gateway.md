# ADR 0013: Operator access through the GKE Connect gateway, not an IP allowlist

- Status: accepted; implementation waits on fleet registration approval.
- Date: 2026-11-01

## Context
The Kubernetes API was reachable only from a /32 allowlist. The operator's public address changed between sessions, and each change needed a reviewed Terraform apply. That is an availability and an access-control problem.

## Options
1. Keep the IP allowlist: simple; fragile; widens access every time the address moves.
2. Public API with no allowlist: rejected.
3. Private control plane plus a bastion or IAP tunnel: more infrastructure to run.
4. Connect gateway (fleet membership plus `connectgateway.googleapis.com`): access is an IAM decision on the operator's Google identity; no network allowlist; audit logs by identity.

## Decision
Option 4. The cluster is registered to a fleet; operators receive `roles/gkehub.gatewayEditor` (or a narrower role) and use `gcloud container fleet memberships get-credentials`. The allowlist is kept only as a fallback until the gateway path is verified.

## Status
Fleet registration was blocked by the automatic safety check in this session. It needs the owner's explicit approval (`gcloud container fleet memberships register llm-lab --gke-cluster us-central1-a/llm-lab --enable-workload-identity`).

## Consequences
Operator access no longer depends on an address; the control plane can later be made private without losing access.
