#!/bin/bash
# 01-deploy-platform.sh — installs Argo CD, nginx ingress, Sentinel, + creates
# the marketly namespace + secrets.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TF_DIR="$SCRIPT_DIR/../terraform"

echo "=== Platform Deployment ==="
echo ""

# Get Terraform outputs
echo "[1/6] Reading Terraform outputs..."
cd "$TF_DIR"
PG_FQDN=$(terraform output -raw postgres_server_fqdn)
PG_USER=$(terraform output -raw postgres_admin_login)
PG_PASS=$(cd "$TF_DIR" && terraform output -raw postgres_password 2>/dev/null || terraform output | grep postgres_password | head -1)
REDIS_HOST=$(terraform output -raw redis_hostname)
echo "  Postgres: $PG_FQDN"
echo "  Redis:    $REDIS_HOST"

# Get secrets from Key Vault
echo ""
echo "[2/6] Fetching secrets from Key Vault..."
KV_NAME=$(terraform output -raw key_vault_name)
LLM_KEY=$(az keyvault secret show --vault-name "$KV_NAME" --name "llm-api-key" --query value -o tsv)
GH_TOKEN=$(az keyvault secret show --vault-name "$KV_NAME" --name "github-token" --query value -o tsv)
STRIPE_KEY=$(az keyvault secret show --vault-name "$KV_NAME" --name "stripe-api-key" --query value -o tsv)
PG_PASS=$(az keyvault secret show --vault-name "$KV_NAME" --name "postgres-password" --query value -o tsv)
REDIS_KEY=$(az redis list-keys --name "$(terraform output -raw redis_hostname | cut -d. -f1)" --resource-group "$(terraform output -raw resource_group_name)" --query primaryKey -o tsv)
echo "  ✓ secrets fetched"

# Create namespace
echo ""
echo "[3/6] Creating namespaces..."
kubectl apply -f "$SCRIPT_DIR/../k8s/namespaces.yaml"
echo "  ✓ namespaces created"

# Install nginx ingress controller
echo ""
echo "[4/6] Installing nginx ingress controller..."
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
helm repo update
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace marketly \
  --set controller.service.externalIPs="{100.100.100.100}" \
  --wait
echo "  ✓ nginx ingress installed"

# Install Argo CD
echo ""
echo "[5/6] Installing Argo CD..."
helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
helm repo update
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --create-namespace \
  --set server.service.type=LoadBalancer \
  --wait
echo "  ✓ Argo CD installed"

# Create the GHCR pull secret
echo ""
echo "[6/6] Creating secrets + GHCR pull secret..."

# GHCR pull secret
kubectl create secret docker-registry ghcr-pull-secret \
  --namespace marketly \
  --docker-server=ghcr.io \
  --docker-username=karimzakzouk \
  --docker-password="$GH_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -

# DB credentials secret
kubectl create secret generic marketly-db-credentials \
  --namespace marketly \
  --from-literal=checkout-url="postgresql://${PG_USER}:${PG_PASS}@${PG_FQDN}:5432/checkout?sslmode=require" \
  --from-literal=payments-url="postgresql://${PG_USER}:${PG_PASS}@${PG_FQDN}:5432/payments?sslmode=require" \
  --from-literal=inventory-url="postgresql://${PG_USER}:${PG_PASS}@${PG_FQDN}:5432/inventory?sslmode=require" \
  --from-literal=users-url="postgresql://${PG_USER}:${PG_PASS}@${PG_FQDN}:5432/users?sslmode=require" \
  --from-literal=shipping-url="postgresql://${PG_USER}:${PG_PASS}@${PG_FQDN}:5432/shipping?sslmode=require" \
  --from-literal=search-url="postgresql://${PG_USER}:${PG_PASS}@${PG_FQDN}:5432/search?sslmode=require" \
  --from-literal=recommendation-url="postgresql://${PG_USER}:${PG_PASS}@${PG_FQDN}:5432/recommendation?sslmode=require" \
  --from-literal=workers-url="postgresql://${PG_USER}:${PG_PASS}@${PG_FQDN}:5432/workers?sslmode=require" \
  --dry-run=client -o yaml | kubectl apply -f -

# App secrets
kubectl create secret generic marketly-secrets \
  --namespace marketly \
  --from-literal=jwt-secret="marketly-jwt-secret-$(date +%s)" \
  --from-literal=stripe-api-key="$STRIPE_KEY" \
  --from-literal=redis-url="${REDIS_HOST}:6380" \
  --from-literal=redis-password="$REDIS_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "  ✓ secrets created"

# Install Sentinel
echo ""
echo "=== Installing Sentinel ==="
helm repo add sentinel https://karimzakzouk.github.io/sentinel/ 2>/dev/null || true
helm repo update
helm upgrade --install sentinel sentinel/sentinel \
  --namespace sentinel \
  --create-namespace \
  --values "$SCRIPT_DIR/../helm/sentinel-values.yaml" \
  --set sentinel.githubToken="$GH_TOKEN" \
  --set sentinel.llm.apiKey="$LLM_KEY" \
  --set sentinel.apiToken="marketly-sentinel-token" \
  --wait

echo "  ✓ Sentinel installed"

# Apply Argo CD apps
echo ""
echo "=== Applying Argo CD Application definitions ==="
kubectl apply -f "$SCRIPT_DIR/../helm/argocd-apps.yaml"
echo "  ✓ Argo CD apps applied — services will sync automatically"

# Apply ingress
kubectl apply -f "$SCRIPT_DIR/../k8s/ingress.yaml"

echo ""
echo "=== Platform deployed ==="
echo ""
echo "Argo CD UI:"
echo "  kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo "  Password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
echo ""
echo "Sentinel API:"
echo "  kubectl port-forward svc/sentinel -n sentinel 8000:8000"
echo "  Token: marketly-sentinel-token"
echo ""
echo "Next: ./scripts/02-start-traffic.sh"
