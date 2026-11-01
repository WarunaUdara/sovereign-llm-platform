# Runbook: GKE lab operations

Project: `llm-k8s-experimental` (never `studed-prod`). Cluster: `llm-lab` (zonal, us-central1-a).
All gcloud calls set `CLOUDSDK_CORE_PROJECT` explicitly. Do not rely on the global default project.

## Bring-up
1. `task preflight`: tools, identity, billing, model hash, cost gate.
2. `task cloud:plan` then `task cloud:up`: cluster, node pool, Artifact Registry, network.
3. `task image:build`: model image pushed by digest; overlay updated.
4. `task deploy` then `task test:smoke`.

## Common failures
- **403 `accessNotConfigured` from OpenTofu:** enable the named API. Wait 1-3 minutes, then re-plan. A saved plan goes stale after a partial apply, so re-run `tofu plan -out=tfplan`.
- **`no active account selected` from kubectl:** `gcloud config set account <your account>`. The global config may be changed outside this repo.
- **Pod `Pending`:** the node pool autoscales from 0. Check `kubectl get events -n llm-serving`. Max is 2 nodes.
- **Image pull `ImagePullBackOff`:** nodes have no internet route. Pulls go through Private Google Access to Artifact Registry only. Check the digest in `overlays/gke/kustomization.yaml` exists in `llm-lab-images`.
- **Autoscaler will not scale down (`no.scale.down.*`):** almost always reservation headroom, not a PDB. See [gke-autoscaler-scale-down](gke-autoscaler-scale-down.md) for the message-id breakdown and the 92-percent-requests trap.

## Access
- The API is limited to the operator /32 (`infra/gcp/terraform.tfvars`). Changing networks requires a new plan.
- Model access is via `kubectl port-forward` (no public load balancer, no LB charge).

## Teardown
1. `task teardown:dry-run`: read the list. Deletes nothing.
2. `task teardown`: type the project ID to confirm. Deletes namespace, then OpenTofu destroy, then runs an inventory sweep.
3. Check the sweep reports zero for every line. If not, do not assume zero spend; delete what is listed.
4. Review the billing report for the project after the next day.
