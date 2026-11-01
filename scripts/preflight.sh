#!/usr/bin/env bash
# Preflight for the GKE lab. Read-only: no billable calls are made.
# Exits non-zero on hard blockers; prints warnings for soft limits.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="llm-k8s-experimental"
FAIL=0
ok()   { echo "  ok    $*"; }
warn() { echo "  warn  $*"; }
bad()  { echo "  FAIL  $*"; FAIL=1; }

echo "== tools"
for t in gcloud tofu kubectl gke-gcloud-auth-plugin gh docker shasum openssl curl; do
  if command -v "$t" >/dev/null 2>&1; then ok "$t"; else bad "$t not installed"; fi
done

echo "== docker (Colima)"
if docker info >/dev/null 2>&1; then
  ok "daemon reachable"
  RUNNING=$(docker ps -q | wc -l | tr -d ' ')
  if (( RUNNING > 0 )); then warn "$RUNNING container(s) running locally. Stop them if RAM is tight."; else ok "no local containers running"; fi
else
  bad "docker daemon not reachable. Start Colima: colima start"
fi

echo "== gcloud identity and project"
ACTIVE=$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null)
if [[ -n "$ACTIVE" ]]; then ok "active account: set (not shown)"; else bad "no active gcloud account. Run: gcloud auth login"; fi
if gcloud projects describe "$PROJECT" --format='value(lifecycleState)' 2>/dev/null | grep -qx ACTIVE; then
  ok "project $PROJECT is ACTIVE"
else
  bad "project $PROJECT not accessible"
fi
BILLING=$(gcloud billing projects describe "$PROJECT" --format='value(billingEnabled)' 2>/dev/null)
[[ "$BILLING" == "True" ]] && ok "billing linked" || bad "billing not linked to $PROJECT"

echo "== gh identity"
gh auth status >/dev/null 2>&1 && ok "gh logged in" || warn "gh not logged in (needed only for the repo push)"

echo "== model artifact"
if "$ROOT/scripts/fetch-model.sh" >/dev/null 2>&1; then
  ok "model present and sha256 matches models/models.lock.yaml"
else
  bad "model missing or hash mismatch. Run: task model:fetch"
fi

echo "== cost gate"
if grep -q "Hard stop time" "$ROOT/evidence/cloud-gate.md" 2>/dev/null; then
  ok "evidence/cloud-gate.md present"
else
  bad "cost gate record missing (evidence/cloud-gate.md)"
fi

echo
if (( FAIL )); then echo "preflight FAILED"; exit 1; fi
echo "preflight passed"
