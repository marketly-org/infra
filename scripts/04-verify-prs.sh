#!/bin/bash
# 04-verify-prs.sh — checks GitHub for PRs opened by Sentinel on all 9 repos.
set -euo pipefail

TOKEN="${GITHUB_TOKEN:?Set GITHUB_TOKEN to a PAT with read access to marketly-org}"
ORG="marketly-org"

REPOS=(
  "checkout-api" "payments-api" "inventory-api" "user-api"
  "search-api" "shipping-api" "analytics-worker" "notification-worker"
  "recommendation-engine"
)

# Ground-truth expected fixes.
# NOTE: these are matched with `grep -qE` (EXTENDED regex) — alternation
# is a bare `|`. The original `\|` form is a LITERAL pipe in ERE and
# never matched anything, which silently zeroed the score for every
# multi-alternative service in runs #1-#10.
declare -A EXPECTED_FIX=(
  ["checkout-api"]="timeout"
  ["payments-api"]="IdempotencyKey"
  ["inventory-api"]="UPDATE.*reserved"
  ["user-api"]="LRU|TTL|setTimeout|eviction"
  ["search-api"]="ok_or|is_none|return Err"
  ["shipping-api"]="isPresent|orElse"
  # Same dual-acceptance as eval-score.py (decision 2026-09-24): the
  # deadlock is unreachable behind the repo's genuine NoMethodError until
  # a redis-client API fix (c.call("SET", ...)) merges; that fix scores.
  ["analytics-worker"]="lock.*order|OrderLock.*InventoryLock|reorder|\.call\(\s*[\"']SET"
  ["notification-worker"]="max_retries.*5"
  ["recommendation-engine"]="shared_mutex|shared_lock|std::mutex"
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

  # Find the most recent Sentinel PR opened during THIS eval run.
  # EVAL_RUN_START (exported by 10-github-eval.sh) guards against stale
  # PRs from earlier runs inflating the score.
  PR_INFO=$(echo "$PR_DATA" | python3 -c "
import json, sys, os, datetime

def ts(s):
    try:
        return datetime.datetime.fromisoformat(s.replace('Z', '+00:00')).timestamp()
    except Exception:
        return 0.0

cutoff = ts(os.environ.get('EVAL_RUN_START', '')) - 60
prs = json.load(sys.stdin)
for pr in prs:
    if 'sentinel' in pr.get('title', '').lower() \
       and (pr.get('head') or {}).get('ref', '').startswith('sentinel/') \
       and (not cutoff or ts(pr.get('created_at') or '') >= cutoff):
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
  # here-string is file-backed in bash: grep -q may exit at the first match
  # without SIGPIPEing a producer (echo|grep -q under pipefail false-negatives
  # on large diffs). GNU grep -E semantics preserved for the patterns (\s etc.)
  if grep -qE "$EXPECTED" <<<"$DIFF"; then
    MATCH="✓ YES"
    MATCHED=$((MATCHED + 1))
  else
    MATCH="✗ NO"
  fi

  printf "%-25s #%-7s %-10s %s\n" "$REPO" "$PR_NUM" "$MATCH" "$PR_TITLE"
done

echo ""
echo "=== Summary: $MATCHED / $TOTAL PRs match ground truth ==="
