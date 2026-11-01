# ADR 0007: LibreChat as the chat frontend, GKE Gateway as the public edge

- Status: accepted
- Date: 2026-10-29

## Context

Employees need a ChatGPT-style UI. The brief asks for open source, production-grade, and hosted on the lab. Building a UI from scratch would take the whole window and would be harder to trust than a maintained project.

## Options considered

| Option | License | Fit | Why not / why |
|---|---|---|---|
| LibreChat (v0.8.8) | MIT | ChatGPT-like UI, custom OpenAI-compatible and Anthropic-compatible endpoints, invite-only accounts, MongoDB | Chosen. Heavy full stack, so we run only the app and MongoDB. |
| Open WebUI | BSD-3 with a branding clause | Strong UI, single container | Bundles embedding and RAG features that need internet at runtime, which our nodes don't have. Branding clause for orgs above 50 users. |
| Build our own | Ours | Full control | Weeks of work for a worse UI and an unaudited auth system. |

## Decision

- Frontend: `ghcr.io/danny-avila/librechat:v0.8.8` (MIT), mirrored into Artifact Registry and pinned by digest. Backed by MongoDB 8.0.20 (pinned).
- Edge: GKE Gateway API on a global external Application Load Balancer. Static IP reserved in OpenTofu; hostname `<ip>.sslip.io`; Google-managed certificate via Certificate Manager; Cloud Armor per-IP rate limit (120 req/min, ban on sustained abuse).
- Access control: invite-only (`ALLOW_REGISTRATION=false`), accounts created by an operator with `scripts/create-chat-user.sh`. No social login.
- Model connection: LibreChat's custom endpoint `Sovereign LLM` points at the model's internal Service and uses the inference key, which lives only in the `chat` namespace as a Secret.

## Consequences

- LibreChat v0.8.8 answers `404 Email does not exist.` on login for unknown addresses (user enumeration). Recorded as T4 in the threat model. Mitigations: `LOGIN_MAX` rate limit, and SSO later.
- One LibreChat replica only (scheduler assumes one process).
- The sslip.io hostname is a lab convenience. A real deployment needs a DNS name the organization owns.

## Reversal

Replace the Deployment and ConfigMap in `deploy/chat/base`. The edge does not depend on LibreChat.
