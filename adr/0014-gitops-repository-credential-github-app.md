# ADR 0014: Argo CD reads the repository through a read-only GitHub App

- Status: accepted (the App must be created by the owner in the GitHub UI).
- Date: 2026-11-01

## Context
The repository is private. Argo CD needs read access. Options: make the repo public (publishes code: rejected), a deploy key (static SSH key, one repository), or a GitHub App (scoped permissions, short-lived installation tokens, rotatable, not tied to a person).

## Decision
GitHub App with `contents: read` and `metadata: read` on this repository only. Its private key is stored in Secret Manager (`argocd-repo-ssh-key` slot, to be renamed to `argocd-github-app-key`) and read by the repo server through Workload Identity. Argo CD uses the App's installation tokens; no static SSH key.

## Fallback
A read-only deploy key, which is what the bootstrap script currently supports. It is static and cannot be rotated without touching the repository, so it is a fallback only.

## Status
The App manifest is in `gitops/github-app-manifest.json`. Creating the App requires the browser flow; the owner does it and then sends the App ID and installation ID.

## Consequences
Until the App exists, GitOps is not live and the repository changes are applied by hand. This is recorded as the top open item.
