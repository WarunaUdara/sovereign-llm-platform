#!/usr/bin/env bash
# Write a kubeconfig that reaches the llm-lab cluster through the GKE Connect gateway (ADR 0013).
# Access is decided by the operator's Google identity (IAM), not by a source IP allowlist.
# Usage: source <(scripts/connect-gateway-config.sh)   or   KUBECONFIG=$(scripts/connect-gateway-config.sh) kubectl ...
set -euo pipefail
PROJECT="llm-k8s-experimental"
PROJECT_NUMBER="40427773756"
OUT="${TMPDIR:-/tmp}/llm-lab-gateway-kubeconfig"
cat > "$OUT" <<KC
apiVersion: v1
kind: Config
clusters:
- name: llm-lab-connect
  cluster:
    server: https://connectgateway.googleapis.com/v1/projects/${PROJECT_NUMBER}/locations/us-central1/gkeMemberships/llm-lab
contexts:
- name: llm-lab-connect
  context: {cluster: llm-lab-connect, user: operator}
current-context: llm-lab-connect
users:
- name: operator
  user:
    exec:
      apiVersion: client.authentication.k8s.io/v1beta1
      command: gke-gcloud-auth-plugin
      provideClusterInfo: true
      interactiveMode: IfAvailable
KC
chmod 600 "$OUT"
echo "$OUT"
