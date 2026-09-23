#!/bin/bash
# 04-verify-prs.sh — checks GitHub for PRs opened by Sentinel on all 9 repos.
set -euo pipefail

TOKEN=$(cd /home/z/my-project/repos/sentinel && git config --get remote.origin.url | sed -n 's|https://[^:]*:\([^@]*\)@.*|\1|p')
ORG="marketly-org"

REPOS=(
  "checkout-api" "payments-api" "inventory-api" "user-api"
  "search-api" "shipping-api" "analytics-worker" "notification-worker"
  "recommendation-engine"
)

# Ground-truth expected fixes
declare -A EXPECTED_FIX=(
  ["checkout-api"]="timeout"
  ["payments-api"]="IdempotencyKey"
  ["inventory-api"]="UPDATE.*reserved"
  ["user-api"]="LRU\|TTL\|setTimeout\|eviction"
  ["search-api"]="ok_or\|is_none\|return Err"
  ["shipping-api"]="isPresent\|orElseThrow\|if.*isPresent"
  ["analytics-worker"]="lock.*order\|OrderLock.*InventoryLock\|reorder"
  ["notification-worker"]="max_retries.*5\|max_retries=5"
  ["recommendation-engine"]="shared_mutex\|shared_lock\|std::mutex"
)

echo "=== Sentinel PR verification ==="
echo ""
printf "%-25s %-8s %-10s %s\n" "REPO" "PR #" "MATCH" "TITLE"
printf "%-25s %-8s %-10s %s\n" "----" "----" "-----" "-----"

TOTAL=0
MATCHED=0

for REPO in "${REPOS[@]}"; do
  TOTAL=$((TOTAL + 1))

  # Get PRs for this repo
  PR_DATA=$(curl -sf -H "Authorization: token $TOKEN" -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/$ORG/$REPO/pulls?state=all&per_page=10&sort=created&direction=desc" 2>/dev/null || echo "[]")

  # Find the most recent Sentinel PR
  PR_INFO=$(echo "$PR_DATA" | python3 -c "
import json, sys
prs = json.load(sys.stdin)
for pr in prs:
    if 'Sentinel' in pr.get('title', '') or 'sentinel' in pr.get('title', '').lower():
        print(f'{pr[\"number\"]}|{pr[\"title\"]}|{pr[\"html_url\"]}')
        break
else:
    print('||')
" 2>/dev/null)

  PR_NUM=$(echo "$PR_INFO" | cut -d'|' -f1)
  PR_TITLE=$(echo "$PR_INFO" | cut -d'|' -f2)

  if [ -z "$PR_NUM" ]; then
    printf "%-25s %-8s %-10s %s\n" "$REPO" "-" "-" "no PR yet"
    continue
  fi

  # Get the PR diff
  DIFF=$(curl -sf -H "Authorization: token $TOKEN" -H "Accept: application/vnd.github.v3.diff" \
    "https://api.github.com/repos/$ORG/$REPO/pulls/$PR_NUM" 2>/dev/null || echo "")

  # Check if the diff contains the expected fix pattern
  EXPECTED="${EXPECTED_FIX[$REPO]}"
  if echo "$DIFF" | grep -qE "$EXPECTED"; then
    MATCH="✓ YES"
    MATCHED=$((MATCHED + 1))
  else
    MATCH="✗ NO"
  fi

  printf "%-25s #%-7s %-10s %s\n" "$REPO" "$PR_NUM" "$MATCH" "$PR_TITLE"
done

echo ""
echo "=== Summary: $MATCHED / $TOTAL PRs match ground truth ==="
