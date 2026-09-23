#!/bin/bash
# 99-destroy.sh — destroys all Azure resources. Kills the bill.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TF_DIR="$SCRIPT_DIR/../terraform"

echo "=== DESTROYING ALL RESOURCES ==="
echo ""
echo "This will delete:"
echo "  - AKS cluster"
echo "  - PostgreSQL server + all databases"
echo "  - Redis cache"
echo "  - Key Vault + secrets"
echo "  - Public IP"
echo "  - Resource group"
echo ""
read -p "Are you sure? Type 'destroy' to confirm: " CONFIRM

if [ "$CONFIRM" != "destroy" ]; then
  echo "Aborted."
  exit 0
fi

cd "$TF_DIR"
terraform destroy -input=false -auto-approve

echo ""
echo "=== ALL RESOURCES DESTROYED ==="
echo "Your Azure bill will stop accumulating."
