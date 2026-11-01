# Runbook: Cluster Autoscaler cannot scale down (PDB vs. no place to move pods)

Cluster: `llm-lab`, zone `us-central1-a`, project `llm-k8s-experimental`.
Symptom reported: `no.scale.down.node.pod.not.enough.pdb`.

**Verdict: the PDB was real but marginal. It caused 2 of the 43 logged scale-down refusals in the
window. The durable reason the node cannot be removed is `no.scale.down.node.no.place.to.move.pods`,
and the underlying cause is reservation headroom, not disruption budgets.**

---

## 1. What the telemetry actually says

Counted from `container.googleapis.com/cluster-autoscaler-visibility`, 2026-10-28T22:00Z to
2026-10-29T03:00Z:

| messageId | Count | Meaning |
|---|---|---|
| `no.scale.down.node.no.place.to.move.pods` | 28 | CA could not find a node to accept the evicted pods |
| `no.scale.down.node.pod.kube.system.unmovable` | 13 | kube-system pods on the node with no controller to recreate them |
| `no.scale.down.node.pod.not.enough.pdb` | 2 | a PDB had `disruptionsAllowed == 0` at that instant |

Reproduce:

```bash
gcloud logging read 'logName="projects/llm-k8s-experimental/logs/container.googleapis.com%2Fcluster-autoscaler-visibility"
  AND timestamp>="2026-10-28T22:00:00Z" AND timestamp<="2026-10-29T03:00:00Z"
  AND jsonPayload.noDecisionStatus.noScaleDown.nodes.reason.messageId!=""' \
  --limit=200 --format='value(jsonPayload.noDecisionStatus.noScaleDown.nodes.reason.messageId)' \
  | tr ' ' '\n' | grep -v '^$' | sort | uniq -c | sort -rn
```

## 2. Why the two PDB events happened (and why they were transient)

Both PDBs in this repo are `maxUnavailable: 1`, not `minAvailable: 1` and not `maxUnavailable: 0`:

```bash
kubectl -n chat get pdb librechat mongo -o jsonpath='{range .items[*]}{.metadata.name}{" maxUnavailable="}{.spec.maxUnavailable}{"\n"}{end}'
```

Kubernetes computes the budget as:

```
desiredHealthy     = expectedPods - maxUnavailable
disruptionsAllowed = currentHealthy - desiredHealthy
```

With one replica and `maxUnavailable: 1`, `desiredHealthy = 0`, so a **Ready** pod always yields
`disruptionsAllowed = 1`. Current state confirms it:

```
NAME        ALLOWED  HEALTHY  DESIRED
librechat   1        1        0
mongo       1        1        0
```

`disruptionsAllowed` therefore only reaches 0 in the window where the pod is **not yet Ready**. The
two events are at 23:21:36 and 23:34:30 on 2026-10-28, minutes after the chat namespace was created
(PDB creation timestamp 23:19:49), while LibreChat was failing its startup probe (it was still
crashing on the `CREDS_KEY` length bug recorded in [chat-operations](chat-operations.md), incident 1).
`currentHealthy = 0` for a pod with no replacement gives 0 allowed disruptions, and the autoscaler
refuses to evict. That is correct behaviour, not a misconfiguration.

**So: do not "fix" this by widening the PDB. It is already at its most permissive useful value.** The
fix is to stop treating a cold start as a steady state, which is what the next section is about.

## 3. Why the node still cannot be removed: 92 percent reserved, 8 percent used

```
$ kubectl describe node | sed -n '/Allocated resources:/,/Events:/p'
gke-llm-lab-inference-32g-...   cpu 3636m (92%)   memory 7.6 GiB (25%)
gke-llm-lab-inference-...       cpu 1779m (92%)   memory 2.7 GiB (42%)

$ kubectl top nodes
gke-llm-lab-inference-32g-...   340m   8%
gke-llm-lab-inference-...       216m  11%
```

Both nodes are at 92 percent of **CPU requests** while consuming 8 to 11 percent of actual CPU. The
autoscaler's scale-down simulation must place every evicted pod on a remaining node, and it schedules
against requests, not utilisation. Nothing fits anywhere. That is `no.place.to.move.pods`, 28 times.

This is the real finding: **requests are the currency of the autoscaler.** A cluster that looks idle
in `kubectl top` can be completely immovable, and the same reservation math blocks a manual
`kubectl drain` during a node upgrade.

## 4. What the report from the assistant got right, and wrong

| Claim | Verdict |
|---|---|
| `no.scale.down.node.pod.not.enough.pdb` was logged for the `inference` node | Correct |
| The message names the pods (`mongo-...`, `librechat-...`), not the PDBs | Correct |
| PDBs use `minAvailable: 1` / `maxUnavailable: 0` and create a permanent block | **Wrong.** Both use `maxUnavailable: 1`; allowed disruptions is 1 today |
| The block is permanent for single-replica workloads | **Wrong.** It is a readiness window, and it clears when the pod reports Ready |
| Current state is healthy at `minNodeCount: 1` | Correct, but incomplete: both nodes are also at 92 percent requests, so scale-down cannot succeed even with no PDB at all |
| Remediation: two LibreChat replicas | **Would break this repo** (see below) |

### Why the suggested remediation is wrong here

1. **`image: ghcr.io/danny-avila/librechat:latest`** violates the digest-pinning rule (`STACK.md`,
   CI step "Reject mutable image tags"), and the nodes have **no internet route**: an image that is
   not mirrored into `llm-lab-images` cannot be pulled at all.
2. **Two LibreChat replicas without Redis** breaks scheduling: the app runs with
   `SCHEDULES_SINGLE_PROCESS=true`, and the runbook states one replica until Redis streams exist
   ([chat-operations](chat-operations.md), "Known upstream issues").
3. **Mongo as a 2-replica Deployment** is not high availability. The volume is `ReadWriteOnce` with
   `strategy: Recreate`; two pods would fight over one disk. A real second member is a replica set,
   not a second replica.
4. **`podAntiAffinity` (preferred)** cannot spread pods that only have two nodes and 92 percent
   reserved CPU on both. Preference is advisory; with no headroom it does nothing.

## 5. What to do instead, in cost order

1. **Right-size requests (the actual fix, free).** Lower the CPU requests for `librechat`, `argocd`,
   `gmp` and the model pods to something close to their observed use, then keep limits where they
   are. Target: at least one node able to absorb the biggest single pod on the other node. Re-measure
   with `kubectl describe node | grep -A3 "Allocated resources"`. This also unblocks drains for node
   upgrades.
2. **Accept a brief interruption for stateful single replicas.** `maxUnavailable: 1` already allows
   eviction; evicting `mongo` costs seconds of downtime plus a volume re-attach, and the PDB does not
   prevent it. Decide this explicitly rather than discovering it during a drain.
3. **If zero downtime is required:** LibreChat 2 replicas + Redis (and `SCHEDULES_SINGLE_PROCESS`
   revisited), Mongo as a 3-member replica set with an anti-affinity rule. That is a phase-2 change,
   not an incident fix.
4. **Do not tune the PDB.** `minAvailable: 1` or `maxUnavailable: 0` on a single replica is the one
   setting that would create the permanent block the report described. Keep `maxUnavailable: 1`.

## 6. Verify

```bash
kubectl get pdb -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,ALLOWED:.status.disruptionsAllowed,HEALTHY:.status.currentHealthy'
kubectl describe node | sed -n '/Allocated resources:/,/Events:/p'
kubectl drain <node> --dry-run=client --ignore-daemonsets --delete-emptydir-data
```

`--dry-run=client` does not contact the eviction API, so it will not show PDB refusals. To test a real
drain safely, cordon first and watch `kubectl get pdb -A -w` while evicting one pod at a time.

## 7. Related

- [chat-operations](chat-operations.md): the `CREDS_KEY` crash loop that made the pods unready.
- [gke-operations](gke-operations.md): bring-up, teardown, and the no-internet-route constraint.
- ADR 0004: scale-to-zero deferred; the same reservation math is why.
