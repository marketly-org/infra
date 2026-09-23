# Marketly Infrastructure

Terraform + Helm + scripts to deploy the full Marketly e-commerce platform on Azure AKS with Sentinel autonomous SRE.

> **No Azure? Run the eval on GitHub Actions instead** — see
> [Sentinel eval on GitHub Actions (kind)](#sentinel-eval-on-github-actions-kind)
> below. Same bugs, same scoring, cluster lives and dies inside one workflow
> job.

## Architecture

9 microservices (8 languages) + Postgres + Redis + Argo CD + Sentinel. All bugs are real production failure modes for Sentinel to detect, diagnose, and fix autonomously.

## Sentinel eval on GitHub Actions (kind)

The full investigation-quality eval without Azure: a kind cluster is created
inside a single workflow job, the 9 services sync via Argo CD, traffic
triggers the planted bugs, Sentinel investigates with Groq and opens PRs,
and `scripts/eval-score.py` scores them against `ground-truth.md`. The
cluster is destroyed with the job — nothing to tear down, nothing to forget.

### One-time setup

1. Add repo secrets (Settings → Secrets and variables → Actions):
   - `MARKETLY_GITHUB_TOKEN` — PAT with `repo` + `read:packages` on
     marketly-org (investigation clones, PR open/merge, post-run reset)
   - `GROQ_API_KEY` — Groq key
2. That's it. The service images pull via node-level containerd auth, and
   Argo CD gets per-repo git credentials created by the driver.

### Run

Actions → **Sentinel Eval (kind)** → Run workflow. Inputs: soak window
(default 45 min), replicas (default 2), autoMerge sandbox gate, model names,
and whether to reset the service repos afterwards (default on — auto-merged
fixes and their `deploy:` commits are force-reverted so the next run finds
the bugs again).

Results land in the job summary (per-service table: incident / status /
confidence / PR / fix-matches-ground-truth) and the `eval-results` artifact
(incidents.json, Sentinel logs, pod snapshots over time).

### Differences vs the AKS path

| | AKS (00/01 scripts) | GHA eval (10 script) |
|---|---|---|
| Cluster | 3-node AKS, standing | 1-node kind, ~2h lifespan |
| Postgres/Redis | Azure PG + Azure Cache | in-cluster (`k8s/eval/`) |
| Runner | your machine + `az login` | ubuntu-latest |
| State between runs | persists | fresh every run |
| Cost | ~$1.10/hr while up | ~60-110 Actions min/run |

Notes:
- Run #1 is a shakeout run — expect to iterate on boot/trigger issues
  before scores mean anything.
- kind's default CNI accepts NetworkPolicy objects but doesn't enforce
  them, so Sentinel's sandbox isolation is nominal in this environment.
- The login-hammer deployment (`k8s/eval/login-hammer.yaml`) accelerates
  /auth/login load so user-api's memory leak OOMs inside the soak window —
  extra traffic, same bug.

## Prerequisites

```bash
# Install tools
brew install terraform az kubectl helm  # macOS
# or: https://learn.hashicorp.com/tutorials/terraform/install-cli

# Login to Azure
az login

# Set subscription (if you have multiple)
az account set --subscription "your-subscription-id"
```

## Quick start

```bash
# 1. Copy + fill in variables
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# Edit terraform.tfvars — add your LLM key, GitHub token, etc.

# 2. Deploy infrastructure (8-12 min, ~$1)
./scripts/00-deploy-infra.sh

# 3. Deploy platform: Argo CD + Sentinel + ingress (3 min)
./scripts/01-deploy-platform.sh

# 4. Start traffic generator (triggers the bugs)
./scripts/02-start-traffic.sh

# 5. Watch Sentinel detect + fix incidents
./scripts/03-watch-incidents.sh

# 6. Verify PRs were opened + merged
./scripts/04-verify-prs.sh

# 7. Verify all pods recovered
./scripts/05-verify-recovery.sh

# 8. DESTROY when done (stops the bill)
./scripts/99-destroy.sh
```

## Cost

| Duration | Cost |
|----------|------|
| 1 hour | ~$1.10 |
| 4 hours | ~$4.40 |
| 1 day | ~$26 |
| 1 week | ~$186 |

**Always run `99-destroy.sh` when done.**

## Services

| Service | Language | Bug |
|---------|----------|-----|
| checkout-api | Python/FastAPI | Missing HTTP timeout |
| payments-api | Go | Missing idempotency key |
| inventory-api | Go | Race condition (read-then-write) |
| user-api | TypeScript/Node | Memory leak (unbounded Map) |
| search-api | Rust/Axum | Panic on edge case (unwrap) |
| shipping-api | Java/Spring | Null pointer (Optional.get) |
| analytics-worker | Ruby/Sidekiq | Deadlock (lock order) |
| notification-worker | Python/Celery | Infinite retry (max_retries=0) |
| recommendation-engine | C++/gRPC | Iterator invalidation |

## Ground truth

See `ground-truth.md` for the expected fix for each bug. The `04-verify-prs.sh` script checks Sentinel's PRs against this.

## Accessing the UIs

```bash
# Argo CD
kubectl port-forward svc/argocd-server -n argocd 8080:443
# Password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d

# Sentinel API
kubectl port-forward svc/sentinel -n sentinel 8000:8000
# Token: marketly-sentinel-token

# Sentinel Web UI
kubectl port-forward svc/sentinel-web -n sentinel 3000:3000
```
