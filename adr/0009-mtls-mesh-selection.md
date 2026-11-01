# ADR 0009: Workload mTLS: mesh choice and the gate before installing it

- Status: proposed, not installed. Decision pending (owner).
- Date: 2026-10-29

## Context
Traffic between LibreChat and the model, and from the model's scraper, is plaintext inside the cluster. The threat model lists this gap. A mesh gives mutual TLS with workload identity (SPIFFE IDs), and can also enforce "only chat may call the model" at L4 and L7.

## Options
| Option | Pros | Cons for this cluster |
|---|---|---|
| **Istio ambient** (ztunnel + istio-cni) | No sidecars, so no per-pod RAM. Strongest mTLS model. | Needs privileged node agents (istio-cni, ztunnel) on every node. GKE Dataplane V2 is Cilium-based; reports conflict on whether it works (a 2024 tutorial says no; a 2026 post says yes with `global.platform=gke`). Node agents require the node-critical class and a ResourceQuota outside kube-system. |
| Istio sidecars | Well documented. | The injected init container needs NET_ADMIN, which the restricted Pod Security profile forbids in `llm-serving` and `chat`. Would need istio-cni anyway. |
| Linkerd | Lightweight Rust proxy, CNCF graduated. | Sidecar + init container: same restricted-profile conflict. Needs its own trust anchor and certificate rotation. |
| Google Cloud Service Mesh (managed) | Google operates the control plane. | Less control; still uses a data plane that touches the node network. Pricing and quota to be checked. |
| App-level TLS (cert-manager issued, each service terminates TLS) | No privileged components; restricted profile intact. | Every service must implement TLS and cert reload. More code, weaker identity model. |

## Recommendation
Istio ambient, **after** a gate: install into a throwaway GKE cluster on the same Dataplane V2 settings, run the full smoke suite and drill D1, and keep it only if both pass. The gate exists because the reports conflict and because a broken CNI breaks every pod.

## Gate (must pass before installing into `llm-lab`)
1. Throwaway cluster, same version and Dataplane V2 flag. Cost: one small node for the test window, then deleted.
2. Install the pinned charts (`istio/base`, `istiod` profile `ambient`, `cni` and `ztunnel` with `platform=gke`). Images are already mirrored under `istio/` in Artifact Registry (1.30.7).
3. `task test:smoke` and `scripts/smoke-chat.sh` pass; drill D1 recovers in under 60 s.
4. Pod-to-pod traffic shows mTLS (`istioctl ztunnel-config` or ztunnel logs).
5. Only then: `PeerAuthentication` STRICT in `llm-serving` and `chat`, and an `AuthorizationPolicy` allowing only the chat service account to call the model.

## Consequences
- Until the gate passes, inter-service traffic stays plaintext. Mitigation: NetworkPolicy restricts who can connect (B4 in the threat model).
- The restricted Pod Security profile remains, because ambient mode keeps the privileged parts on the node and out of the application pods.

## Gate result (2026-11-01, throwaway cluster `mesh-gate`, deleted afterwards)
- Istio 1.30.7 ambient: `istiod` ran once the distroless image variants were mirrored (the chart default for this version is `-distroless`; mirror entries added).
- `istio-cni` on GKE COS: the default CNI binary path `/opt/cni/bin` is read-only. It only works with `cniBinDir=/home/kubernetes/bin` and `cniConfDir=/etc/cni/net.d`. It then wrote a chained config into `10-gke-cni.conflist`, which is the change that must be tested against Dataplane V2 before any production use.
- `ztunnel`: pod stuck in ImagePullBackOff at the last check. Not yet resolved, so mTLS was NOT verified.
- Decision status: still proposed. Do not install into `llm-lab` until a run reaches verified mTLS (ztunnel Ready, traffic between two ambient pods shown as mTLS, and the existing smoke suites still pass).
