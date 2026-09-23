#!/bin/bash
# 03-watch-incidents.sh — polls Sentinel API for incidents + prints them.
set -euo pipefail

SENTINEL_TOKEN="marketly-sentinel-token"

echo "=== Watching Sentinel incidents ==="
echo "Press Ctrl+C to stop."
echo ""

# Port-forward Sentinel API in the background
kubectl port-forward svc/sentinel -n sentinel 8000:8000 >/dev/null 2>&1 &
PF_PID=$!
trap "kill $PF_PID 2>/dev/null" EXIT

sleep 2

SEEN=()

while true; do
  # Get all incidents
  INCIDENTS=$(curl -sf -H "Authorization: Bearer $SENTINEL_TOKEN" \
    "http://localhost:8000/incidents?limit=50" 2>/dev/null || echo "[]")

  # Parse + print new ones
  echo "$INCIDENTS" | python3 -c "
import json, sys
incidents = json.load(sys.stdin)
for inc in incidents:
    inc_id = inc.get('incident_id', '')[:8]
    service = inc.get('cluster', {}).get('service', '?')
    status = inc.get('status', '?')
    root_cause = inc.get('state', {}).get('root_cause', {})
    if root_cause:
        statement = root_cause.get('statement', '')[:80]
        confidence = root_cause.get('confidence', 0)
    else:
        statement = '(investigating...)'
        confidence = 0
    print(f'  [{inc_id}] {service:<20} status={status:<15} conf={confidence:.0%} cause={statement}')
" 2>/dev/null || true

  echo "---"
  sleep 10
done
