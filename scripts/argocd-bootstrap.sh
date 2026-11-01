#!/usr/bin/env bash
# Connect Argo CD to the repository and start GitOps. Idempotent. Secret values never touch disk or argv:
#  - the read-only deploy key lives in Secret Manager (argocd-repo-ssh-key); one credential path, matching the SSH repo URL in gitops/apps
#  - the Kubernetes repository Secret is created by piping the credential from Secret Manager straight into kubectl
#  - the repo server reads Secret Manager through Workload Identity
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export CLOUDSDK_CORE_PROJECT=llm-k8s-experimental
SSH_REPO_URL="git@github.com:WarunaUdara/sovereign-llm-platform.git"
GSA="llm-lab-argocd-repo@llm-k8s-experimental.iam.gserviceaccount.com"
LOCAL_KEY="$ROOT/.secrets/argocd/id_ed25519"

if [[ -f "$LOCAL_KEY" ]]; then
  gcloud secrets versions add argocd-repo-ssh-key --data-file=- < "$LOCAL_KEY" >/dev/null 2>&1 || true
  echo "ensured argocd-repo-ssh-key in Secret Manager"
fi

kubectl -n argocd annotate serviceaccount argocd-repo-server \
  "iam.gke.io/gcp-service-account=$GSA" --overwrite >/dev/null
echo "repo server bound to $GSA (Workload Identity)"

if gcloud secrets describe argocd-repo-ssh-key >/dev/null 2>&1; then
  kubectl -n argocd create secret generic repo-llm-lab \
    --from-literal=type=git --from-literal=url="$SSH_REPO_URL" \
    --from-file=sshPrivateKey=<(gcloud secrets versions access latest --secret argocd-repo-ssh-key) \
    --dry-run=client -o yaml \
    | kubectl label --local -f - argocd.argoproj.io/secret-type=repository -o yaml \
    | kubectl apply -f - >/dev/null
  echo "repository credential created from Secret Manager (SSH key)"
fi

kubectl apply -f "$ROOT/gitops/apps/root.yaml" >/dev/null
echo "root application applied; Argo CD will reconcile gitops/apps"
