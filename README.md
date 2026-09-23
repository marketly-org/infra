# Marketly Infrastructure

Terraform + Helm + scripts to deploy the full Marketly e-commerce platform on Azure AKS with Sentinel autonomous SRE.

## Architecture

9 microservices (8 languages) + Postgres + Redis + Argo CD + Sentinel. All bugs are real production failure modes for Sentinel to detect, diagnose, and fix autonomously.

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
