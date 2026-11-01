# ADR 0006: GKE cloud-first lab in the experimental project

- Status: accepted (supersedes ADR 0001)
- Date: 2026-10-29

## Context

Owner has a GCP trial with about $271 of credit and about 6 days left, a dedicated project `llm-k8s-experimental`, and a 16 GB Mac running Colima with 4 GiB for the VM. The local kind cluster used 1.5 GiB and was removed. The owner wants a GKE deployment.

## Decision

- **Cluster:** zonal GKE Standard, us-central1-a, release channel REGULAR, Dataplane V2 (managed Cilium, enforces NetworkPolicy), private nodes, Workload Identity, Shielded nodes, system-only logging and metrics.
- **Node pool:** one e2-standard-2 on-demand pool, autoscaling 1 to 2. No Spot (PREEMPTIBLE quota is 0).
- **Networking:** custom VPC, one subnet with Private Google Access, no Cloud NAT, deny-internet-ingress firewall. Nodes have no route to the public internet by design.
- **Images:** the model is baked into a digest-pinned image in Artifact Registry. The Dockerfile re-checks the model SHA-256 at build time. This removes runtime downloads and the writable model volume.
- **Access:** Kubernetes API restricted to the operator /32. Model reached through `kubectl port-forward`. No public load balancer in this phase.
- **Identity:** node SA with five least-privilege project roles; workloads use Workload Identity; no keys in the cluster.
- **Teardown:** namespace delete, OpenTofu destroy, label sweep, local cleanup. Dry-run first.

## Alternatives rejected

- **Autopilot:** bills per pod resource, and system pod overhead is not controllable at this size. Standard with one small pool is cheaper and easier to reason about for a lab.
- **Regional cluster:** doubles the control-plane footprint and is not needed for a 6-day lab. Recorded as a production gap.
- **Public Gateway with TLS:** adds an external LB hourly charge and needs a domain. Deferred to phase 2.
- **Cloud NAT:** a per-hour charge for a lab that doesn't need internet egress. Image pulls go through Artifact Registry instead.
- **Remote state bucket:** itself a billable resource. Local gitignored state is used and must be backed up before any destroy.

## Verified (2026-10-29)

- Cluster RUNNING, node Ready, model pod 1/1 Running on the digest `sha256:1042f4fb…`.
- Smoke suite: 10 of 10 pass against GKE.
- Egress: control pod in another namespace reaches Google APIs (HTTP 404), the model pod times out. The policy is enforced.

## Consequences

- Public internet is not reachable from any pod. Any future dependency must come through Private Google Access or the mirror.
- Port-forward is the only access path. Operators need `gke-gcloud-auth-plugin`.
- Cost is measured and recorded in `evidence/cloud-gate.md`.

## Reversal

Run `task teardown`. Re-create with `task cloud:up-all` if needed.
