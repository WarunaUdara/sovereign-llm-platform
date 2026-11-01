# ADR 0011: No predictive autoscaling; reactive node autoscaling plus fixed replicas

- Status: accepted.
- Date: 2026-11-01

## Context
A predictive scaler was researched for LLM inference. The sources were vendor material and the Predictive Horizontal Pod Autoscaler project, which itself warns that it needs tuning on real history. We have only days of metrics, and no benchmark exists for CPU LLM inference.

## Options
1. Predictive scaler (forecast in-flight requests, scale ahead): needs history we do not have; a wrong forecast over-provisions or under-provisions; adds a controller we must operate.
2. Reactive pod autoscaling (KEDA on queue depth): useful only with several replicas per node pool and a queue signal; on this 4-vCPU node a third replica adds no compute.
3. Reactive node autoscaling (GKE cluster autoscaler, 1 to 2 nodes) plus a fixed replica count per service: already deployed and observed to scale.

## Decision
Option 3. Replicas are fixed (LibreChat 2, Gemma 2 where memory allows, embedding 1). Node autoscaling stays reactive and capped at 2 nodes, which also caps cost.

## Trigger to revisit
Sustained `llamacpp:requests_deferred > 0` for more than 10 minutes, measured in Cloud Monitoring, on a node pool that is already at its maximum. Then the next step is more nodes, not a smarter pod scaler.

## Consequences
The KEDA manifest vendored in `gitops/keda/` is not installed and must not be installed without a new ADR. The predictive design remains in `docs/PLAN-V3` as history.
