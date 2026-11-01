# ADR 0001: Local-first, zero-cost default profile

- Status: superseded by ADR 0006 (2026-10-29). The local kind profile was removed to free RAM and the GKE lab was built with trial credit.
- Date: 2026-10-29

## Context

Trial credit is $270 with about 4 days left. GPU quota is unavailable on the trial. Cloud nodes, load balancers, and egress consume credit even though cluster management is covered once.

## Decision

The default profile is a local kind cluster on the Mac. Cloud is a separate, gated profile (COST_GUARDRAILS.md).

## Alternatives rejected

- Cloud-first GKE deployment: spends credit before the platform is proven, and makes teardown a precondition for progress.
- Managed inference APIs: removes the sovereignty story the project is about.

## Consequences

- Scale behavior of GKE node pools is not exercised until the cloud gate passes. It is documented as a gap.
- The Docker VM memory limit is the main capacity constraint.

## Reversal

Pass the cloud gate in COST_GUARDRAILS.md and record the decision here.
