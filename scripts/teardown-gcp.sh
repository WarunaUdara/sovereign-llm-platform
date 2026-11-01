#!/usr/bin/env bash
# Tear down the GKE lab: Kubernetes workloads first, then OpenTofu-managed infrastructure, then an
# independent inventory sweep by label. Deletes nothing in --dry-run mode.
# Refuses to run against any project other than the lab project.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="llm-k8s-experimental"
ZONE="us-central1-a"
REGION="us-central1"
CLUSTER="llm-lab"
LABEL="lab=sovereign-llm-lab"
KCTX="gke_${PROJECT}_${ZONE}_${CLUSTER}"
export CLOUDSDK_CORE_PROJECT="$PROJECT"

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1
LOG="$ROOT/evidence/teardown-$(date -u +%Y%m%dT%H%M%SZ).log"
mkdir -p "$ROOT/evidence"
log() { echo "[$(date -u +%H:%M:%S)] $*" | tee -a "$LOG"; }
FAILED=0

log "teardown start (dry_run=$DRY_RUN) project=$PROJECT"

if (( ! DRY_RUN )); then
  echo "This permanently deletes the GKE cluster, node pool, network, Artifact Registry images, and the node service account."
  read -r -p "Type the project ID to confirm ($PROJECT): " answer
  [[ "$answer" == "$PROJECT" ]] || { log "aborted: confirmation did not match"; exit 1; }
fi

if [[ "$(gcloud config get-value project 2>/dev/null)" != "$PROJECT" ]]; then
  log "note: global gcloud project is not $PROJECT; this script uses CLOUDSDK_CORE_PROJECT=$PROJECT"
fi

log "== 1. Kubernetes workloads (release the endpoint before infrastructure)"
if kubectl config get-contexts -o name 2>/dev/null | grep -qx "$KCTX"; then
  # chat first: deleting the Gateway is what releases the global load balancer GKE created for it.
  for ns in chat llm-serving; do
    if (( DRY_RUN )); then
      log "would delete namespace $ns and wait"
    else
      kubectl --context "$KCTX" delete namespace "$ns" --wait=true --timeout=300s >>"$LOG" 2>&1 \
        && log "namespace $ns deleted" || { log "namespace $ns delete failed; continuing to infra destroy"; FAILED=1; }
    fi
  done
  if (( ! DRY_RUN )); then
    # Confirm the Gateway's load balancer forwarding rules are gone before OpenTofu removes the network.
    for i in $(seq 1 30); do
      n=$(gcloud compute forwarding-rules list --global --format='value(name)' 2>/dev/null | grep -c . || true)
      [[ "$n" == 0 ]] && break
      sleep 20
    done
    log "global forwarding rules remaining before destroy: $n"
  fi
else
  log "no kube context $KCTX; skipping workload delete"
fi

log "== 2. OpenTofu destroy (state-aware)"
if (( DRY_RUN )); then
  (cd "$ROOT/infra/gcp" && tofu plan -destroy -input=false -no-color -var "authorized_cidr=$(sed -n 's/.*= *"\(.*\)".*/\1/p' terraform.tfvars 2>/dev/null || echo 0.0.0.0/32)" 2>&1 | tail -15) | tee -a "$LOG"
else
  (cd "$ROOT/infra/gcp" && tofu destroy -input=false -auto-approve) >>"$LOG" 2>&1 \
    && log "tofu destroy completed" || { log "tofu destroy FAILED. See log; run the sweep below"; FAILED=1; }
fi

log "== 3. Inventory sweep (independent of OpenTofu state)"
inv() { # inv <label> <command...>
  local name="$1"; shift
  local out
  out="$("$@" 2>/dev/null | grep -v '^$' || true)"
  local n=$(printf '%s\n' "$out" | grep -c . || true)
  log "  $name remaining: $n"
  [[ -n "$out" ]] && printf '%s\n' "$out" | sed 's/^/      /' | tee -a "$LOG"
  (( n > 0 )) && FAILED=1
}
inv "GKE clusters"          gcloud container clusters list --format="value(name)"
inv "compute instances"     gcloud compute instances list --format="value(name)" --filter="labels.lab=sovereign-llm-lab OR name~^gke-llm-lab"
inv "forwarding rules"      gcloud compute forwarding-rules list --format="value(name)"
inv "external addresses"    gcloud compute addresses list --format="value(name)"
inv "disks"                 gcloud compute disks list --format="value(name)" --filter="name~^gke-llm-lab"
inv "VPC networks (lab)"    gcloud compute networks list --format="value(name)" --filter="name~^llm-lab"
inv "service accounts (lab)" gcloud iam service-accounts list --format="value(email)" --filter="email~^llm-lab-nodes"
inv "artifact repos (lab)"  gcloud artifacts repositories list --location="$REGION" --format="value(name)" --filter="name~llm-lab-images"

log "== 4. Local cleanup (no cloud effect)"
if (( ! DRY_RUN )); then
  rm -f "$ROOT/.secrets/api-keys" "$ROOT/infra/gcp/tfplan"
  kubectl config delete-context "$KCTX" >/dev/null 2>&1 || true
  kubectl config delete-cluster "$KCTX" >/dev/null 2>&1 || true
  log "local API key and plan file removed; kube context removed"
fi

echo
if (( DRY_RUN )); then
  log "RESULT: dry run. Nothing was deleted. Resources listed above are expected to be removed by a real run."
  exit 0
fi
if (( FAILED )); then
  log "RESULT: NOT CLEAN. Something remains; inspect the sweep above before assuming zero spend."
  exit 1
fi
log "RESULT: inventory clean (dry_run=$DRY_RUN). Log: $LOG"
