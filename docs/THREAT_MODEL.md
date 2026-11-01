# Threat model: sovereign LLM lab (GKE, public chat front door)

Scope: the public chat URL, the chat namespace, the model namespace, the GKE cluster, and the supply chain that builds them. Method: trust boundaries, then per-boundary threats (STRIDE-lite). Each threat names its control and the check that proves it. Status column: **verified** means a command in this repo or in `evidence/` ran it; **designed** means the control exists but its test is not yet written; **gap** means not addressed.

## Assets
- Prompts and completions (sensitive by policy, even though the lab uses synthetic data).
- LibreChat accounts, password hashes, and session tokens (MongoDB).
- The model's inference key and metrics key.
- Encryption and session secrets: `CREDS_KEY`, `CREDS_IV`, `JWT_SECRET`, `JWT_REFRESH_SECRET`.
- The model weights (Apache-2.0) and the images that carry them.
- Cloud spend and the operator's gcloud identity.

## Trust boundaries

| # | Boundary | Crossing | Control | Status |
|---|---|---|---|---|
| B1 | Internet to edge | HTTPS to the global external ALB | TLS with a Google-managed certificate; HTTP redirected to HTTPS; Cloud Armor per-IP rate limit | verified (TLS, redirect, 200 on `/`) |
| B2 | Edge to chat pods | ALB source ranges to LibreChat 3080 | NetworkPolicy allows only 130.211.0.0/22 and 35.191.0.0/16 | designed |
| B3 | Chat to MongoDB | LibreChat to Mongo 27017 | NetworkPolicy: Mongo ingress only from LibreChat; Mongo has no egress | designed |
| B4 | Chat to model | LibreChat to llm-serving 8080 | NetworkPolicy both sides; bearer inference key | verified (200 from the chat pod) |
| B5 | Model to internet | Model pod egress | Default-deny egress; nodes have no internet route | verified (policy blocks; control reaches Google APIs) |
| B6 | Namespace to namespace | DNS and metrics | DNS only to kube-dns; metrics only from `gmp-system` | verified (DNS probe; scrape up=1) |
| B7 | Operator to cluster | kubectl to the API | Control-plane authorized networks = operator /32; Workload Identity; no legacy ABAC | verified (settings in `evidence/cluster-state-*.txt`) |
| B8 | Build to runtime | Images and model weights | Digest pins; model SHA-256 checked at image build; mirrored third-party images in Artifact Registry | verified (digests in lock files) |

## Threats

| ID | Threat (STRIDE) | Control | Residual risk | Status |
|---|---|---|---|---|
| T1 | Spoofing: anonymous user reads conversations | LibreChat requires login; `/api/convos` returns 401 without a session | Session theft via XSS or a stolen device | verified (smoke-chat) |
| T2 | Spoofing: self-registration by a stranger | `ALLOW_REGISTRATION=false`; register returns 403 | An operator account is a single point of trust | verified (smoke-chat) |
| T3 | Spoofing: brute force on login | `LOGIN_MAX=7`; Cloud Armor 120 req/min per IP | Distributed brute force across IPs | designed |
| T4 | **Information disclosure: user enumeration** | None in the app. LibreChat v0.8.8 returns `404 Email does not exist.` for unknown emails | An attacker can learn which emails have accounts | **verified (finding)**. Mitigation: rate limit (T3); SSO later |
| T5 | Tampering: model or image swapped | Digest pins; hash check at build; lock files | Pins go stale; no image signature verification yet | designed (cosign is a gap) |
| T6 | Repudiation: no record of who asked what | LibreChat stores conversations per user in MongoDB | Workload logs are not shipped; no audit log export | gap (trade-off for privacy) |
| T7 | Information disclosure: prompts in logs | Workload logs off (system components only); server logs no bodies | Operator debugging is harder | verified (sentinel test on model; logging config in OpenTofu) |
| T8 | Information disclosure: model calls out and leaks | Default-deny egress; no internet route | Depends on the policy engine (Dataplane V2) | verified |
| T9 | Denial of service: flood at the edge | Cloud Armor rate limit and ban | Large distributed floods; no Cloud Armor WAF rule sets | designed |
| T10 | Denial of service: huge prompts | Context 4096, output 512, LibreChat body limits | One user can still take both model slots | designed (quotas are phase 2) |
| T11 | Elevation: container escape | Non-root (UID 1000 / 999 / 10001); read-only root FS; no capabilities; seccomp RuntimeDefault; no SA tokens | Shared node kernel | verified (pod security context captured) |
| T12 | Elevation: metrics token used for inference | Separate key line; chat never receives it | The metrics key is a valid inference key | accepted limitation (ADR 0008) |
| T13 | Secret exposure: keys in Git | `.secrets/` ignored; scans before each commit; keys never printed | A dev machine compromise exposes local secrets | verified (commit scans) |
| T14 | Secret exposure: keys in the cluster | Kubernetes Secrets (etcd encryption at rest is GKE default); RBAC limits the collector to one Secret | Secrets are readable by anyone with `get secrets` in the namespace | designed (CMEK is a gap) |
| T15 | Operator account compromise | Single operator, gcloud keyed to the owner account; ADC quota project pinned | No MFA enforcement in this repo | gap |
| T16 | Denial of service via cost (unbounded autoscaling) | Node pool max 2; budget alerts (notify only) | Notify-only budgets do not stop spend | verified (budget created) |
| T17 | Stale credentials after rotation | `create-api-key.sh --rotate` and `create-chat-secrets.sh --rotate` documented | Rotation is manual | designed |
| T18 | Front door down without notice | Uptime check and alert on the public URL | Notification only; on-call is the owner | designed (alert wired; not yet fired in a test) |

## Known weaknesses kept on purpose (and why)
- **T4 user enumeration** is an upstream behavior in LibreChat v0.8.8. We record it instead of hiding it. The fix belongs in upstream or in SSO.
- **T12** is a consequence of llama-server having one key type. The gateway in phase 2 issues scoped keys and removes this.
- **T6** is the trade-off for privacy: no workload logs means no audit trail of prompts. A real deployment would keep metadata-only audit logs.

## Out of scope
Compliance certification, third-party penetration testing, real employee data, and a hardware root of trust. These are not claimed.
