# ADR 0012: Runtime secret injection through the GKE Secret Manager CSI driver, one Workload Identity per workload

- Status: accepted.
- Date: 2026-11-01

## Context
Secrets must not live in Git, in Terraform state, or as long-lived Kubernetes objects created by hand. The first implementation synced Secret Manager values into Kubernetes Secrets through the CSI driver's `secretObjects`. On this cluster the GKE-managed driver is forbidden from listing Secrets cluster-wide, so the sync fails.

## Options
1. Kubernetes Secrets created by scripts from local files: simple; values are copied into etcd; rotation is manual; rejected.
2. GKE Secret Manager CSI driver, applications read files: values come from Secret Manager at pod start; each workload authenticates with its own Workload Identity; no sync object is needed.
3. External Secrets Operator: syncs Secret Manager into Kubernetes Secrets with its own identity; the cleanest long-term model; requires installing a cluster-wide controller.

## Decision
Option 2 now, with option 3 as the planned migration when a cluster-wide controller is approved. Each workload has one Google service account and reads only its own secrets (`model-secrets`, `chat-secrets`, `argocd-repo`). Values are added to Secret Manager as versions by `scripts/sync-secret-manager.sh`, from stdin.

## Verified
- Gemma pod reads its key file from the CSI mount; the model accepts the injected key (fingerprint match).
- The LibreChat process environment holds the injected inference key (fingerprint match with the model's key).
- A real chat message through the public front door streams a reply.

## Exception (stated)
PodMonitoring can only read Kubernetes Secrets, so the metrics token is a single Kubernetes Secret, readable only by the managed collector through a Role limited to that one Secret.

## Consequences
Rotation = add a new Secret Manager version, then restart the workload. Applications read files and export them in their start command (LibreChat), which couples them to the mount path; this is documented in the manifest.
