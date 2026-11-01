# GitOps with Argo CD (app-of-apps)

Status: definitions written, **not installed**. Argo CD needs read access to this repository. The repository is private, so the owner must choose one of:

1. **Make the repository public.** Argo CD clones over HTTPS with no credential. Simplest, but it publishes the repo. Outward-facing: needs an explicit yes.
2. **GitHub App.** Create an App with read-only `Contents` on this repo. Its private key is stored in Google Secret Manager and synced into Argo CD at runtime. Rotatable, no long-lived token in Git.

Flow once access exists:
- `root` Application points at `gitops/apps/`. It creates one Application per workload.
- Each workload Application points at a Kustomize overlay (`deploy/...`), with automated sync, prune, and self-heal.
- Changes reach the cluster only through merged commits to `main`. CI builds images and the pinned digest is committed (the build job currently records it in the job summary; the next step is a bot PR that updates the overlay).
