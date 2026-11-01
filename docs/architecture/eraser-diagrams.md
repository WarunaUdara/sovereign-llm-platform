# Eraser diagram source

The Eraser workspace supplied in the request requires sign-in in the available browser session. These are paste-ready Eraser diagram-as-code sources for creating the revised diagrams there.

## 1. Logical architecture (default local profile and optional GKE profile)

```text
title Sovereign LLM serving lab - bounded profiles
direction right

People [icon: users]
Developer M4 [icon: laptop] {
  Git repo [icon: github]
  Taskfile and scripts [icon: terminal]
  kind local cluster [icon: kubernetes] {
    Local Gateway [icon: api]
    Model API adapter [icon: api]
    KEDA [icon: keda]
    ModelEndpoint chart [icon: helm]
    Metrics and Grafana [icon: grafana]
    llama.cpp or CPU vLLM [icon: docker]
  }
  Model files with SHA256 [icon: file]
}

Optional GCP trial project - billable resources consume trial credit [icon: gcp] {
  Budget alerts and TTL cleanup [icon: clock]
  IAM and Workload Identity [icon: shield]
  VPC [icon: network] {
    Single HTTPS endpoint [icon: lock]
    Zonal GKE Standard [icon: kubernetes] {
      System node pool min 1 [icon: server] {
        Gateway [icon: api]
        KEDA operator and HTTP add-on [icon: keda]
        Model API adapter [icon: api]
        Prometheus short retention [icon: prometheus]
        Grafana [icon: grafana]
        Policy enforcement [icon: shield]
      }
      Inference pool min 0 max 1 [icon: server] {
        ModelEndpoint [icon: helm]
        Small CPU model pod [icon: docker]
      }
      GKE-supported dataplane [icon: network]
    }
    Optional private GCS model artifact [icon: gcp-cloud-storage]
    Optional Artifact Registry image [icon: gcp-artifact-registry]
  }
}

Employees [icon: users]

Git repo > Taskfile and scripts: deploy, test, inventory, teardown
Taskfile and scripts > kind local cluster: strict zero-cash profile
Taskfile and scripts > IAM and Workload Identity: optional short-lived GCP profile
Git repo > ModelEndpoint chart: Git reviewed values
Model files with SHA256 > llama.cpp or CPU vLLM: local artifact
kind local cluster > Local Gateway: port-forward only
Local Gateway > Model API adapter: auth, quotas, API compatibility
Model API adapter > KEDA: metrics and scale intent
KEDA > ModelEndpoint chart: replicas 0 to 1
ModelEndpoint chart > llama.cpp or CPU vLLM: internal service only
Metrics and Grafana > Local Gateway: scrape metrics
Metrics and Grafana > llama.cpp or CPU vLLM: scrape metrics

Employees > Single HTTPS endpoint: TLS plus identity and rate limit
Single HTTPS endpoint > Gateway: only public application path
Gateway > Model API adapter: validated OpenAI or Anthropic request
Model API adapter > KEDA operator and HTTP add-on: scale intent; cold request held only after protocol test
KEDA operator and HTTP add-on > ModelEndpoint: scale 0 to 1
ModelEndpoint > Inference pool min 0 max 1: unschedulable pod triggers bounded node autoscaler
Inference pool min 0 max 1 > Small CPU model pod: CPU runtime, fixed model hash
Small CPU model pod > Model API adapter: internal streamed response
Zonal GKE Standard > System node pool min 1: system workloads keep at least one node available
GKE-supported dataplane > Policy enforcement: managed dataplane and Kubernetes NetworkPolicy
ModelEndpoint > Optional private GCS model artifact: read-only fetch if chosen
ModelEndpoint > Optional Artifact Registry image: pinned digest
Budget alerts and TTL cleanup > Zonal GKE Standard: delete after lab window
Budget alerts and TTL cleanup > Single HTTPS endpoint: remove forwarding rule and address
IAM and Workload Identity > ModelEndpoint: least privilege identity

note Strict zero-cash mode does not include GKE. GKE node/network charges consume trial credits; free-tier credit offsets cluster management only. No GPU in the required path.
```

## 2. Cold start and streamed request sequence

```text
sequence-diagram
title Cold request to a zero-replica model

Client > HTTPS Gateway: POST /v1/chat/completions or /v1/messages
HTTPS Gateway > API Adapter: authenticate, validate size, quota
API Adapter > HTTP Interceptor: route selected model; request deadline begins
HTTP Interceptor > KEDA: pending request observed
KEDA > Model Deployment: replicas 0 to 1
Model Deployment > Scheduler: pod requests bounded CPU and memory
Scheduler > Cluster Autoscaler: pod Pending if no eligible capacity
Cluster Autoscaler > GCE: add node within max pool and quota
GCE > Scheduler: node Ready
Scheduler > Model Deployment: pod scheduled
Model Deployment > Registry or model store: pull pinned image and model hash
Model Deployment > Readiness Probe: model fully loaded
Readiness Probe > HTTP Interceptor: endpoint ready
HTTP Interceptor > Model API: forward original synchronous request
Model API > HTTP Interceptor: SSE token stream
HTTP Interceptor > API Adapter: stream and propagate cancellation
API Adapter > HTTPS Gateway: compatible response
HTTPS Gateway > Client: SSE response

note Measure node provisioning, image pull, model load, queue wait, TTFT, and token generation separately. A timeout returns a documented error; never silently queue forever.
```

## 3. Provision, operate, and teardown

```text
flowchart-diagram
direction down
title Reproducible lab lifecycle

Start [shape: oval]
Profile check [shape: diamond]
Run local kind [shape: box]
Check billing, quota, region and TTL [shape: box]
Create bounded zonal GKE [shape: box]
Deploy platform then model [shape: box]
SDK and security smoke tests [shape: box]
Record latency, capacity and credits [shape: box]
Delete ingress and forwarding resources [shape: box]
Delete workloads and wait for finalizers [shape: box]
Delete cluster and project-labeled resources [shape: box]
Independent inventory sweep [shape: box]
Any billable leftovers [shape: diamond]
Delete GCP project as final fallback [shape: box]
Verify empty inventory and save evidence [shape: oval]
End [shape: oval]

Start > Profile check
Profile check > Run local kind: strict zero-cash
Profile check > Check billing, quota, region and TTL: optional trial-credit profile only
Check billing, quota, region and TTL > Create bounded zonal GKE
Create bounded zonal GKE > Deploy platform then model
Run local kind > Deploy platform then model
Deploy platform then model > SDK and security smoke tests
SDK and security smoke tests > Record latency, capacity and credits
Record latency, capacity and credits > Delete ingress and forwarding resources
Delete ingress and forwarding resources > Delete workloads and wait for finalizers
Delete workloads and wait for finalizers > Delete cluster and project-labeled resources
Delete cluster and project-labeled resources > Independent inventory sweep
Independent inventory sweep > Any billable leftovers
Any billable leftovers > Delete GCP project as final fallback: yes
Any billable leftovers > Verify empty inventory and save evidence: no
Delete GCP project as final fallback > Verify empty inventory and save evidence
Verify empty inventory and save evidence > End
```
