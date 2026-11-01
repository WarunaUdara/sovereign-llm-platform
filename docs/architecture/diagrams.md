# Architecture diagrams (Mermaid)

Sources for the article figures. They render on GitHub. Keep each diagram in sync with the manifests it describes; the file paths in each section say where the truth lives.

## 1. System context

```mermaid
flowchart LR
  user([Employee<br/>browser]) -->|HTTPS, session cookie| edge[GKE Gateway<br/>global external ALB<br/>Cloud Armor, managed cert]
  operator([Operator<br/>gcloud, kubectl]) -->|IAM, /32 allowlist| api[(GKE control plane)]
  edge --> chat[LibreChat v0.8.8<br/>chat namespace]
  chat -->|bearer inference key| model[llama-server x2<br/>Qwen2.5-0.5B GGUF<br/>llm-serving namespace]
  model -. no egress .-> internet((internet))
  monitor[Managed Prometheus<br/>+ Cloud Monitoring] -->|scrape, token| model
  grafana[Grafana] -->|PromQL| frontend[GMP frontend] --> monitor
  ci([GitHub Actions]) -->|OIDC, no key| wif[Workload Identity Federation]
  wif --> registry[(Artifact Registry<br/>digest-pinned images)]
```

## 2. Containers and trust boundaries

Boundaries follow [docs/THREAT_MODEL.md](../THREAT_MODEL.md): B1 edge, B2 edge to chat, B3 chat to database, B4 chat to model, B5 model egress, B6 cross-namespace, B7 operator to cluster, B8 build to runtime.

```mermaid
flowchart TB
  subgraph Internet
    U[Browser]
  end
  subgraph GCP["GCP project llm-k8s-experimental"]
    subgraph Edge["Edge (managed)"]
      LB["Global ALB + Cloud Armor<br/>B1: TLS, rate limit"]
    end
    subgraph GKE["GKE zonal Standard, Dataplane V2, private nodes"]
      subgraph chat["ns chat (restricted PSA, default-deny)"]
        LC["LibreChat<br/>non-root, read-only FS"]
        MG[(MongoDB 8.0)]
      end
      subgraph serving["ns llm-serving (restricted PSA, default-deny)"]
        M1["llama-server replica A"]
        M2["llama-server replica B"]
      end
      subgraph obs["ns observability + gmp-public"]
        GF[Grafana]
        FE["GMP frontend<br/>read-only WI identity"]
      end
    end
    SM[(Secret Manager)]
    AR[(Artifact Registry)]
    CM[(Cloud Monitoring)]
  end
  U -->|"B1 HTTPS"| LB --> LC
  LC -->|"B3"| MG
  LC -->|"B4 bearer key"| M1
  LC -->|"B4 bearer key"| M2
  M1 -. "B5 egress denied" .-> X((no route))
  GF --> FE --> CM
  M1 -->|"metrics scrape"| CM
  M2 -->|"metrics scrape"| CM
```

## 3. Deployment and network policy topology

```mermaid
flowchart LR
  subgraph np["NetworkPolicy allow-list (everything else denied)"]
    direction LR
    lb[(Google LB ranges<br/>130.211.0.0/22, 35.191.0.0/16)] -->|3080| lc[LibreChat]
    lc -->|27017| mg[MongoDB]
    lc -->|8080| mdl[llama-server]
    k6[k6 load job] -->|8080| mdl
    gmp[gmp-system collector] -->|8080 metrics| mdl
    gf[Grafana] -->|9090| fe[GMP frontend]
    dns[(kube-dns 53)] -.-> lc
  end
```

## 4. Request sequence: one message, browser to tokens

```mermaid
sequenceDiagram
  autonumber
  participant B as Browser
  participant G as Gateway (ALB)
  participant L as LibreChat
  participant M as llama-server (replica)
  B->>G: POST /api/agents/chat (HTTPS, session)
  G->>L: forward (health-checked backend)
  L->>L: validate session, build prompt (small: no tools)
  L->>M: POST /v1/chat/completions (stream, bearer key)
  M->>M: prefill prompt (about 30 tok/s on 2 vCPU)
  loop generation
    M-->>L: SSE token chunk
    L-->>B: stream to browser
  end
  M-->>L: [DONE]
```

## 5. Identity and secret flow (no static keys)

```mermaid
flowchart LR
  gha[GitHub Actions job<br/>id-token: write] -->|OIDC token| wif[WIF pool llm-lab-github<br/>condition: repo = lab AND ref = main]
  wif -->|short-lived token| ci_sa[SA llm-lab-ci<br/>push image, GKE developer]
  pod_m[model pod<br/>KSA model-endpoint] -->|Workload Identity| sa_m[SA model-secrets<br/>reads llm-api-keys, llm-metrics-token]
  pod_c[chat pod<br/>KSA librechat] -->|Workload Identity| sa_c[SA chat-secrets<br/>reads librechat-* and llm-api-keys]
  sa_m --> sm[(Secret Manager)]
  sa_c --> sm
  sm -->|CSI mount at runtime| pod_m
  sm -->|CSI mount at runtime| pod_c
```

Status: the identities and grants exist; the CSI mounts are not wired yet, because the secret values have not been synced (see the article plan, section 4). Until then the workloads still use Kubernetes Secrets created by scripts.

## 6. Delivery pipeline

```mermaid
flowchart LR
  dev[Commit to main] --> ci1[secret scan<br/>gitleaks]
  dev --> ci2[static<br/>OpenTofu, shell, render<br/>digest check]
  ci1 --> build
  ci2 --> build[build job<br/>main only, WIF]
  build --> fetch[fetch model<br/>SHA-256 verified]
  fetch --> bake[docker buildx<br/>bake model into image]
  bake --> push[push to Artifact Registry]
  push --> digest[digest recorded<br/>overlay pin]
  digest -. next: bot PR .-> git[(Git)]
  git -. Argo CD root app .-> cluster[(GKE)]
```

Status: CI up to the build is running and green. Argo CD sync is designed (`gitops/`) and not installed.

## 7. Failure and recovery view

```mermaid
flowchart TB
  f1[Kill model replica] -->|drill D1b| r1[Other replica serves<br/>0 failed probes in 40 s]
  f2[Kill only model pod] -->|drill D1| r2[Back in 16 s<br/>hypothesis was 30-60 s]
  f3[Agent prompt 5,029 tokens] -->|incident 5| r3[Plain-chat config<br/>reply in about 2 s]
  f4[Egress from model pod] -->|policy| r4[Blocked; control reaches Google APIs]
  f5[Load generator outside the policy] -->|run 1 and 2| r5[Denied by default-deny<br/>fixed by an explicit allow]
```
