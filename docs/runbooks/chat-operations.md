# Runbook: chat front door (LibreChat + MongoDB + Gateway)

Public URL: https://chat.example.com (static IP reserved in OpenTofu; hostname is `<ip>.sslip.io`).
Namespace: `chat`. Model: `llm-serving` (see [gke-operations.md](gke-operations.md)).

## Routine checks
- `./scripts/smoke-chat.sh`: 7 public checks (redirect, TLS, UI, auth gate, invite-only, no session on bad credentials).
- `kubectl -n chat get pods`: expect `librechat` 1/1 and `mongo` 1/1.
- Model path from inside the chat pod: fetch `/v1/models` with `LLM_API_KEY` returns 200.

## Create a user (invite-only)
`./scripts/create-chat-user.sh <email> "<display name>" <username>` and type the password at the prompt.
Self-registration is closed (`ALLOW_REGISTRATION=false`); the register endpoint returns 403.

## Incidents from the first build (2026-10-29)

### 1. LibreChat refused to start: CREDS_KEY length
- Symptom: `CrashLoopBackOff`; log says `CREDS_KEY must be exactly 64 hexadecimal characters`.
- Cause: `openssl rand -hex 32` wrote a trailing newline, and `--from-file` kept it (65 characters).
- Fix: `scripts/create-chat-secrets.sh` strips the newline. Secrets were regenerated (no user data existed yet).
- Lesson: LibreChat fails closed on weak or malformed credentials. That's the behavior you want. Never edit the key in place on a live system that holds encrypted data.

### 2. Gateway stayed `Pending` (no GatewayClass)
- Symptom: Gateway conditions `Accepted=Unknown`, "Waiting for controller". `gke-l7-global-external-managed` missing.
- Cause: this cluster was built with `http_load_balancing.disabled = true`. GKE's L7 Gateway classes depend on the HTTP LB addon.
- Fix: addon re-enabled in `infra/gcp/main.tf`. Gateway reached `Programmed=True`.

### 3. Pods could not resolve any service name (EAI_AGAIN)
- Symptom: LibreChat log `getaddrinfo EAI_AGAIN mongo.chat.svc.cluster.local`. Later, every name failed from pods on the second node.
- Diagnosis (in order): labels on kube-dns matched the policy; a probe pod on the same node resolved the **kube-dns pod IP** (10.20.0.6) but not the **service IP** (10.30.0.10); the NodeLocal DNSCache listener (169.254.20.10) also timed out there.
- Fix 1 (policy, kept): `allow-dns` now also permits the NodeLocal address and the kube-dns service IP. Commit `network: allow DNS to GKE NodeLocal DNSCache...`.
- Fix 2 (cluster): NodeLocal DNSCache disabled (`dns_cache_config.enabled = false`, recorded in OpenTofu). After this, lookups succeeded from the LibreChat pod.
- Open question: the root cause in the NodeLocal listener was not isolated. Re-test if the add-on is re-enabled.

### 4. HTTPS returned `000` for several minutes after the Gateway was up
- Cause: the Certificate Manager authorization first ran at 22:46 UTC, before the load balancer served the name (`RESOLVED_TO_NOT_SERVING`). It was retried and became `AUTHORIZED`; the certificate went `ACTIVE` about 30 minutes after the first attempt.
- Action: none needed. Check with `gcloud certificate-manager certificates describe llm-lab-edge-cert --location=global`.

## Known upstream issues (accepted, documented)
- **User enumeration:** `POST /api/auth/login` answers `404 Email does not exist.` for unknown emails. Tracked in [THREAT_MODEL.md](../THREAT_MODEL.md) (T4). Mitigation options: rate limit (`LOGIN_MAX` is set to 7), SSO only, or an upstream fix.
- **Scheduler needs one replica:** set `SCHEDULES_SINGLE_PROCESS=true`. Keep one LibreChat replica until Redis streams are added.
- **Metrics endpoint:** `METRICS_SECRET` is unset, so `/metrics` returns 401 to everyone. Set it before scraping.

### 5. "The model provider could not complete this request. Request timed out." on a plain "hi"
- Symptom: a one-word message took minutes and then failed. Reproduced on 2026-10-29.
- Diagnosis (in order, each step measured):
  1. Model logs: `request (5029 tokens) exceeds the available context size (2048 tokens)`. The prompt was 5,029 tokens for "hi".
  2. LibreChat logs: `Title generation timeout`, then `Upstream model error` about three minutes later.
  3. Root cause: LibreChat's **agent path** wraps every message in a large system prompt and tool capabilities. On this 2-vCPU node the model prefills at about 32 tokens per second, so 5,000 tokens need about 2.5 minutes before the first output token. Title generation added a second generation on the same CPU.
  4. Contributing: the context was 4096 total, so each of two slots held 2048 tokens. The load balancer's backend timeout was the default 30 seconds.
- Fix (small commits):
  - `chat: plain-chat config`: agent tools, capabilities, file search, and title generation off; activity labels off (they call OpenAI, which this lab cannot reach).
  - `model: context 8192`: 4096 tokens per slot.
  - `edge: backend timeout 600 s`.
- Verified after the fix: the same "hi" arrives as **30 tokens** and completes in **1.6 s**. A real message through LibreChat's chat route streamed a reply in about 2 s. Evidence: `evidence/chat-verification-*.txt` and the notes in `docs/INFERENCE.md`.
- Detail: LibreChat rejects requests whose User-Agent is not a browser (`Illegal request`, from `uaParser`). That is a deliberate anti-bot control. Test with a browser User-Agent.

## Where to look (dashboards and logs)
See [dashboards.md](dashboards.md).
