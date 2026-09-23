#!/bin/bash
# 05-verify-recovery.sh — checks all pods are Running (no CrashLoopBackOff).
set -euo pipefail

echo "=== Pod recovery verification ==="
echo ""

# Check all marketly pods
echo "[1/2] Pod status in marketly namespace:"
echo ""
kubectl get pods -n marketly -o wide 2>/dev/null | head -20

echo ""
echo "[2/2] Pod health summary:"

UNHEALTHY=$(kubectl get pods -n marketly --no-headers 2>/dev/null | grep -vE "Running|Completed" | wc -l)
RUNNING=$(kubectl get pods -n marketly --no-headers 2>/dev/null | grep -c "Running")
TOTAL=$(kubectl get pods -n marketly --no-headers 2>/dev/null | wc -l)

echo "  Total pods:  $TOTAL"
echo "  Running:     $RUNNING"
echo "  Unhealthy:   $UNHEALTHY"

if [ "$UNHEALTHY" -eq 0 ]; then
  echo ""
  echo "=== ALL PODS HEALTHY ✓ ==="
else
  echo ""
  echo "=== $UNHEALTHY pod(s) still unhealthy ==="
  echo "Unhealthy pods:"
  kubectl get pods -n marketly --no-headers 2>/dev/null | grep -vE "Running|Completed" | awk '{print "  " $1 " — " $3}'
fi

echo ""
echo "=== Sentinel incident summary ==="
kubectl port-forward svc/sentinel -n sentinel 8000:8000 >/dev/null 2>&1 &
PF_PID=$!
sleep 2

curl -sf -H "Authorization: Bearer marketly-sentinel-token" \
  "http://localhost:8000/incidents?limit=20" 2>/dev/null | python3 -c "
import json, sys
incidents = json.load(sys.stdin)
resolved = [i for i in incidents if i.get('status') == 'resolved']
investigating = [i for i in incidents if i.get('status') == 'investigating']
failed = [i for i in incidents if i.get('status') == 'failed']
print(f'  Resolved:     {len(resolved)}')
print(f'  Investigating: {len(investigating)}')
print(f'  Failed:       {len(failed)}')
" 2>/dev/null || echo "  (could not reach Sentinel API)"

kill $PF_PID 2>/dev/null
