# Eraser diagram source: sovereign LLM platform (verified 2026-10-31)

Diagram-as-code for Eraser. Paste each block into a new Eraser file, or use the Eraser MCP once it is connected. Icon names follow the set already accepted in this project; if one does not resolve, substitute a similar icon. Nothing here shows secret values, the operator address, or any capability that is not deployed; dashed grey boxes are designed or deliberately not installed.

## 1. Full platform

```text
title Sovereign LLM Platform on GKE: GitOps, retrieval, and zero-trust workloads
direction right

Users [icon: users] {
  Employee browser [icon: laptop]
  Operator laptop [icon: terminal]
}

GitHub [icon: github] {
  Repo main [icon: git]
  CI pipeline [icon: github-actions]
}

Pending owner action [icon: shield] {
  Read-only deploy key [icon: lock]
}

GCP project llm-k8s-experimental [icon: gcp] {
  Secret Manager [icon: gcp-secret-manager]
  Artifact Registry images [icon: gcp-artifact-registry]
  Cloud Monitoring [icon: gcp-cloud-monitoring]
  Workload Identity Federation [icon: shield]

  VPC llm-lab-vpc [icon: gcp-virtual-private-cloud] {
    Edge [icon: gcp-cloud-load-balancing] {
      Static IP and sslip hostname [icon: dns]
      Global external ALB via GKE Gateway [icon: gcp-cloud-load-balancing]
      Managed certificate [icon: lock]
      Cloud Armor rate limit [icon: gcp-cloud-armor]
    }

    GKE zonal Standard llm-lab [icon: kubernetes] {
      Control plane [icon: kubernetes] {
        Dataplane V2 Cilium eBPF [icon: network]
        Workload Identity [icon: shield]
      }

      Node pool inference e2-standard-2 [icon: server]
      Node pool inference-32g e2-highmem-4 [icon: server]
      Cluster autoscaler reactive 1-2 nodes [icon: kubernetes]

      Namespace chat [icon: kubernetes] {
        LibreChat v0.8.8 [icon: api]
        MongoDB 8.0.20 [icon: mongodb]
        Secrets CSI chat-secrets [icon: gcp-secret-manager]
        k6 load Job on demand [icon: gauge]
      }

      Namespace llm-serving [icon: kubernetes] {
        Gemma 4 E2B chat llama.cpp [icon: docker]
        EmbeddingGemma 2 llama.cpp [icon: docker]
        Qwen 0.5B baseline x2 [icon: docker]
        Secrets CSI model-secrets [icon: gcp-secret-manager]
        Metrics token Secret [icon: lock]
      }

      Namespace observability [icon: grafana] {
        Grafana 13.2.5 [icon: grafana]
      }
      Namespace gmp-public [icon: prometheus] {
        Managed Prometheus frontend [icon: prometheus]
      }
      Namespace gmp-system [icon: prometheus] {
        Managed collector [icon: prometheus]
      }
      Namespace argocd [icon: argocd] {
        Argo CD v3.5.6 [icon: argocd]
        Repo server [icon: argocd]
      }
    }
  }
}

Not installed [icon: shield] {
  Service mesh mTLS [icon: shield]
  Retrieval step in chat [icon: api]
  Predictive autoscaling dropped [icon: dollar-sign]
}

Users > Edge: HTTPS 1
Edge > LibreChat v0.8.8: 2 backend on 3080, Google ranges only
LibreChat v0.8.8 > Gemma 4 E2B chat llama.cpp: 3 OpenAI API, inference key
LibreChat v0.8.8 > EmbeddingGemma 2 llama.cpp: retrieval embeddings
LibreChat v0.8.8 > MongoDB 8.0.20: users and conversations
Gemma 4 E2B chat llama.cpp > LibreChat v0.8.8: 4 stream tokens back
Secrets CSI chat-secrets > LibreChat v0.8.8: files at runtime
Secrets CSI model-secrets > Gemma 4 E2B chat llama.cpp: model key file
Secret Manager > Secrets CSI chat-secrets: Workload Identity
Secret Manager > Secrets CSI model-secrets: Workload Identity
Workload Identity Federation > CI pipeline: OIDC, no keys
CI pipeline > Artifact Registry images: build and push by digest
Repo main > CI pipeline: gitleaks, static checks, digest check
Repo main > Argo CD v3.5.6: pull and sync (pending deploy key)
Read-only deploy key > Argo CD v3.5.6: repo credential from Secret Manager
Argo CD v3.5.6 > GKE zonal Standard llm-lab: automated sync, prune, self-heal
Artifact Registry images > Gemma 4 E2B chat llama.cpp: digest-pinned pull
Gemma 4 E2B chat llama.cpp > Cloud Monitoring: 5 metrics via scrape
Managed collector > Gemma 4 E2B chat llama.cpp: scrape every 30 s, token
Managed Prometheus frontend > Cloud Monitoring: read-only identity
Grafana 13.2.5 > Managed Prometheus frontend: PromQL
Cloud Monitoring > Grafana 13.2.5: dashboard panels
Cloud Armor rate limit > Global external ALB via GKE Gateway: per-IP policy
Gemma 4 E2B chat llama.cpp > Internet: denied by NetworkPolicy
```

## 2. Request sequence

```text
title Request path: browser to tokens (measured)
direction down

Employee browser [icon: laptop]
Global ALB [icon: gcp-cloud-load-balancing]
Cloud Armor [icon: gcp-cloud-armor]
LibreChat [icon: api]
Gemma 4 E2B chat [icon: docker]

Employee browser > Global ALB: 1 HTTPS, sslip hostname
Global ALB > Cloud Armor: 2 per-IP rate check
Cloud Armor > LibreChat: 3 backend health-checked on /readyz
LibreChat > Gemma 4 E2B chat: 4 chat completion, inference key
Gemma 4 E2B chat > LibreChat: 5 stream, about 19 tok/s prefill, 8 tok/s generation
LibreChat > Employee browser: 6 reply streamed, about 20 s typical
```

## 3. Delivery and identity chain

```text
title Delivery and secret zero: no static keys
direction right

GitHub Actions job [icon: github-actions]
OIDC token [icon: lock]
Workload Identity Federation [icon: shield]
CI service account [icon: gcp-iam]
Artifact Registry [icon: gcp-artifact-registry]
GKE cluster [icon: kubernetes]
Argo CD [icon: argocd]
Secret Manager [icon: gcp-secret-manager]

GitHub Actions job > OIDC token: 1 issues token, repo and main only
OIDC token > Workload Identity Federation: 2 exchange
Workload Identity Federation > CI service account: 3 short-lived credential
CI service account > Artifact Registry: 4 push image by digest
Argo CD > GKE cluster: 5 reconcile manifests
Secret Manager > GKE cluster: 6 CSI mount through Workload Identity
```

## 4. Icon fallbacks

If an icon name does not resolve in Eraser, use these substitutes:

| Component | Preferred icon | Fallback |
|---|---|---|
| MongoDB | mongodb | database |
| Gauge (load) | gauge | dollar-sign |
| Cloud DNS / sslip hostname | dns | network |
| Cloud Monitoring | gcp-cloud-monitoring | prometheus |
| Cloud Armor | gcp-cloud-armor | shield |
| Workload Identity Federation | shield | lock |
| CI service account | gcp-iam | lock |
| Dataplane V2 | network | kubernetes |
| Argo CD | argocd | kubernetes |
| llama.cpp containers | docker | server |
