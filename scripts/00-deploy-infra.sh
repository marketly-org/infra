#!/bin/bash
# 00-deploy-infra.sh — provisions all Azure resources via Terraform.
#
# Prerequisites:
#   - az login (with student subscription)
#   - terraform installed
#   - terraform.tfvars filled in (copy from terraform.tfvars.example)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TF_DIR="$SCRIPT_DIR/../terraform"

echo "=== Marketly Infrastructure Deployment ==="
echo ""

# Check prerequisites
echo "[1/5] Checking prerequisites..."
command -v terraform >/dev/null 2>&1 || { echo "ERROR: terraform not installed"; exit 1; }
command -v az >/dev/null 2>&1 || { echo "ERROR: az CLI not installed"; exit 1; }
az account show >/dev/null 2>&1 || { echo "ERROR: not logged in to Azure — run 'az login'"; exit 1; }
[ -f "$TF_DIR/terraform.tfvars" ] || { echo "ERROR: terraform.tfvars not found — copy from terraform.tfvars.example and fill in"; exit 1; }
echo "  ✓ all prerequisites met"

# Terraform init
echo ""
echo "[2/5] Initializing Terraform..."
cd "$TF_DIR"
terraform init -upgrade
echo "  ✓ terraform initialized"

# Terraform plan
echo ""
echo "[3/5] Planning (this takes ~30s)..."
terraform plan -out=tfplan -input=false
echo "  ✓ plan ready"

# Terraform apply
echo ""
echo "[4/5] Applying (this takes ~8-12 minutes)..."
terraform apply -input=false -auto-approve tfplan
echo "  ✓ infrastructure provisioned"

# Output the kubeconfig command
echo ""
echo "[5/5] Configuring kubectl..."
KUBECONFIG_CMD=$(terraform output -raw kubeconfig_command)
echo "  Run: $KUBECONFIG_CMD"
eval "$KUBECONFIG_CMD"
echo "  ✓ kubectl configured"

echo ""
echo "=== Infrastructure deployed successfully ==="
echo ""
echo "Outputs:"
terraform output
echo ""
echo "Next: ./scripts/01-deploy-platform.sh"
