#!/usr/bin/env bash
# Mirror third-party images into Artifact Registry and record their digests in images/images.lock.yaml.
# GKE nodes have no internet route, so every runtime image must come from our registry.
#   ./scripts/mirror-images.sh              mirror every entry (copies only what is missing)
#   ./scripts/mirror-images.sh grafana      mirror only the named entries; other lock entries are kept
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="${PROJECT_ID:-llm-k8s-experimental}"
REGION="us-central1"
AR="${REGION}-docker.pkg.dev/${PROJECT}/llm-lab-images"
LOCK="$ROOT/images/images.lock.yaml"
ONLY=("$@")

# name|source|target-name
MIRRORS=(
  "librechat|registry.librechat.ai/librechat-ai/librechat:v0.8.8|librechat:v0.8.8"
  "mongo|mongo:8.0.20|mongo:8.0.20"
  "gmp-frontend|gke.gcr.io/prometheus-engine/frontend:v0.15.3-gke.0|frontend:v0.15.3-gke.0"
  "grafana|docker.io/grafana/grafana:13.2.5-distroless|grafana:13.2.5-distroless"
  "istio-pilot|docker.io/istio/pilot:1.30.7|istio/pilot:1.30.7"
  "istio-ztunnel|docker.io/istio/ztunnel:1.30.7|istio/ztunnel:1.30.7"
  "istio-install-cni|docker.io/istio/install-cni:1.30.7|istio/install-cni:1.30.7"
  "istio-proxyv2|docker.io/istio/proxyv2:1.30.7|istio/proxyv2:1.30.7"
  "k6|docker.io/grafana/k6:1.5.0|k6:1.5.0"
  "istio-pilot-distroless|docker.io/istio/pilot:1.30.7-distroless|istio/pilot:1.30.7-distroless"
  "istio-install-cni-distroless|docker.io/istio/install-cni:1.30.7-distroless|istio/install-cni:1.30.7-distroless"
  "istio-ztunnel-distroless|docker.io/istio/ztunnel:1.30.7-distroless|istio/ztunnel:1.30.7-distroless"
  "istio-proxyv2-distroless|docker.io/istio/proxyv2:1.30.7-distroless|istio/proxyv2:1.30.7-distroless"
  "argocd|quay.io/argoproj/argocd:v3.5.6|argocd:v3.5.6"
  "redis|docker.io/library/redis:7.2.11-alpine|redis:7.2.11-alpine"
  "redis-argocd|public.ecr.aws/docker/library/redis:8.2.3-alpine|redis:8.2.3-alpine"
  "keda|ghcr.io/kedacore/keda:2.21.0|keda:2.21.0"
  "keda-metrics-apiserver|ghcr.io/kedacore/keda-metrics-apiserver:2.21.0|keda-metrics-apiserver:2.21.0"
  "keda-admission-webhooks|ghcr.io/kedacore/keda-admission-webhooks:2.21.0|keda-admission-webhooks:2.21.0"
)

gcloud auth print-access-token | docker login -u oauth2accesstoken --password-stdin "${REGION}-docker.pkg.dev" >/dev/null

# Digest of an image already in Artifact Registry, or empty if absent.
ar_digest() {
  docker buildx imagetools inspect "$1" --format '{{json .Manifest}}' 2>/dev/null \
    | python3 -c 'import sys,json; print(json.load(sys.stdin)["digest"])' 2>/dev/null || true
}

for entry in "${MIRRORS[@]}"; do
  IFS='|' read -r name src target <<< "$entry"
  if (( ${#ONLY[@]} )) && [[ ! " ${ONLY[*]} " == *" $name "* ]]; then continue; fi
  dest="$AR/$target"
  digest="$(ar_digest "$dest")"
  if [[ -n "$digest" ]]; then
    echo "already mirrored: $name -> $digest"
  else
    # Retry: Docker Hub and other registries rate-limit or drop connections transiently.
    for attempt in 1 2 3 4; do
      docker buildx imagetools create --tag "$dest" "$src" >/dev/null 2>&1 && break
      [[ $attempt -eq 4 ]] && { echo "failed to mirror $src after 4 attempts" >&2; exit 1; }
      echo "mirror attempt $attempt for $src failed; retrying" >&2; sleep $((attempt * 30))
    done
    digest="$(ar_digest "$dest")"
  fi
  [[ -n "$digest" ]] || { echo "could not read digest for $dest" >&2; exit 1; }
  echo "mirrored $name -> $digest"
  # Merge this entry into the lock file (other entries are kept).
  python3 - "$LOCK" "$name" "$src" "$dest" "$digest" <<'PY'
import sys, re
lock, name, src, dest, digest = sys.argv[1:]
header = ("# Third-party images mirrored into Artifact Registry. Digests are what GKE pulls.\n"
          "# Regenerate with scripts/mirror-images.sh; do not edit digests by hand.\n")
try:
    text = open(lock).read()
except FileNotFoundError:
    text = ""
entries = {}
for m in re.finditer(r"^  (\S+):\n    source: (.*)\n    mirror: (.*)\n    digest: (\S+)\n", text, re.M):
    entries[m.group(1)] = (m.group(2), m.group(3), m.group(4))
entries[name] = (src, dest, digest)
out = header + "mirrors:\n"
for k in sorted(entries):
    s, d, g = entries[k]
    out += f"  {k}:\n    source: {s}\n    mirror: {d}\n    digest: {g}\n"
open(lock, "w").write(out)
PY
done
echo "lock: $LOCK"
