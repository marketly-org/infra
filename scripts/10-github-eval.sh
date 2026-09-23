#!/bin/bash
# 10-github-eval.sh — Sentinel investigation-quality eval on GitHub Actions.
#
# Runs inside a workflow job on an ubuntu-latest runner with a kind cluster
# already created by .github/workflows/eval.yml (which injects GHCR pull
# credentials into the node's containerd, so the private service images
# pull without per-pod imagePullSecrets).
#
# Phases:
#   1. Record pre-eval SHAs of the 9 service repos (for the reset step)
#   2. Boot in-cluster Postgres + Redis (replaces Azure PG / Azure Cache)
#   3. Create every secret the 9 deployments reference
#   4. Install ingress-nginx
#   5. Install Argo CD, wire git credentials, sync all 9 services
#   6. Scale services to $REPLICAS (fit the single kind node)
#   7. Install Sentinel (chart 1.7.0) with Groq + GitHub token
#   8. Start traffic + soak for $WAIT_MINUTES, snapshotting state
#   9. Score Sentinel's PRs vs ground truth, write step summary + artifacts
#  10. Reset service repos to pre-eval SHAs (default on)
#
# Required env:
#   GITHUB_TOKEN  PAT with repo + read:packages on marketly-org
#   GROQ_API_KEY  Groq API key
# Optional env (defaults):
#   WAIT_MINUTES=45  REPLICAS=2  MIN_SANDBOX_LEVEL=3  RESET_REPOS=true
#   FAST_MODEL=llama-3.1-8b-instant  FRONTIER_MODEL=llama-3.3-70b-versatile
#
# Exit code: 0 = eval ran (score is in the summary, whatever it is);
# 1 = harness broke (nothing deployed, or zero incidents detected).

set -euo pipefail
cd "$(dirname "$0")/.."

ORG=marketly-org
REPOS=(
  checkout-api payments-api inventory-api user-api search-api
  shipping-api analytics-worker notification-worker recommendation-engine
)
API=https://api.github.com
ART="$PWD/eval-artifacts"

WAIT_MINUTES="${WAIT_MINUTES:-45}"
REPLICAS="${REPLICAS:-2}"
MIN_SANDBOX_LEVEL="${MIN_SANDBOX_LEVEL:-3}"
RESET_REPOS="${RESET_REPOS:-true}"
FAST_MODEL="${FAST_MODEL:-llama-3.1-8b-instant}"
FRONTIER_MODEL="${FRONTIER_MODEL:-llama-3.3-70b-versatile}"
SENTINEL_API_TOKEN="marketly-sentinel-token"

# Guard rails
WAIT_MINUTES=$(( WAIT_MINUTES > 240 ? 240 : WAIT_MINUTES ))

: "${GITHUB_TOKEN:?Set GITHUB_TOKEN to a PAT with repo + read:packages on marketly-org}"
: "${GROQ_API_KEY:?Set GROQ_API_KEY}"

mkdir -p "$ART"

log() { echo; echo "=== $* ==="; }

api() {
  curl -sf -H "Authorization: token $GITHUB_TOKEN" \
       -H "Accept: application/vnd.github+json" "$@"
}

# ---------------------------------------------------------------- phase 1
log "Phase 1/10: recording pre-eval SHAs (for reset)"
for r in "${REPOS[@]}"; do
  SHA=$(api "$API/repos/$ORG/$r/git/ref/heads/main" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["object"]["sha"])')
  echo "$SHA" > "$ART/$r.sha"
  echo "  $r @ ${SHA:0:7}"
done

# ---------------------------------------------------------------- phase 2
log "Phase 2/10: namespaces + in-cluster Postgres + Redis"
kubectl apply -f k8s/namespaces.yaml
kubectl apply -f k8s/eval/postgres.yaml
kubectl apply -f k8s/eval/redis.yaml
kubectl -n marketly wait --for=condition=ready pod -l app=postgres --timeout=240s
kubectl -n marketly wait --for=condition=ready pod -l app=redis --timeout=240s
echo "  postgres + redis ready"

# ---------------------------------------------------------------- phase 3
log "Phase 3/10: secrets"
PG_USER=marketly
PG_PASS=marketly-eval
PG_HOST=postgres.marketly.svc.cluster.local
REDIS_PASS=marketly-eval
REDIS_HOST=redis.marketly.svc.cluster.local

# Go services (payments, inventory) use lib/pq, which defaults to
# sslmode=require; the in-cluster Postgres has no TLS, so those two URLs
# must opt out explicitly. Python (psycopg2) and Ruby (pg) default to
# prefer and fall back to plaintext on their own.
kubectl -n marketly create secret generic marketly-db-credentials \
  --from-literal=checkout-url="postgresql://$PG_USER:$PG_PASS@$PG_HOST:5432/checkout" \
  --from-literal=payments-url="postgresql://$PG_USER:$PG_PASS@$PG_HOST:5432/payments?sslmode=disable" \
  --from-literal=inventory-url="postgresql://$PG_USER:$PG_PASS@$PG_HOST:5432/inventory?sslmode=disable" \
  --from-literal=users-url="postgresql://$PG_USER:$PG_PASS@$PG_HOST:5432/users" \
  --from-literal=shipping-url="postgresql://$PG_USER:$PG_PASS@$PG_HOST:5432/shipping" \
  --from-literal=search-url="postgresql://$PG_USER:$PG_PASS@$PG_HOST:5432/search" \
  --from-literal=recommendation-url="postgresql://$PG_USER:$PG_PASS@$PG_HOST:5432/recommendation" \
  --from-literal=notifications-url="postgresql://$PG_USER:$PG_PASS@$PG_HOST:5432/notifications" \
  --from-literal=workers-url="postgresql://$PG_USER:$PG_PASS@$PG_HOST:5432/workers" \
  --from-literal=analytics-user="$PG_USER" \
  --from-literal=analytics-password="$PG_PASS" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n marketly create secret generic marketly-redis-credentials \
  --from-literal=url="redis://:$REDIS_PASS@$REDIS_HOST:6379/0" \
  --dry-run=client -o yaml | kubectl apply -f -

# No SMTP server exists on purpose — undeliverable mail is what drives the
# notification-worker retry bug. Credentials just need to exist for the pod
# to start.
kubectl -n marketly create secret generic marketly-smtp-credentials \
  --from-literal=username=eval \
  --from-literal=password=eval \
  --dry-run=client -o yaml | kubectl apply -f -

# No carrier service exists on purpose — an empty carrier response is what
# triggers the shipping-api Optional.get NPE.
kubectl -n marketly create secret generic marketly-carrier-credentials \
  --from-literal=api-key=eval-carrier-key \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n marketly create secret generic marketly-secrets \
  --from-literal=jwt-secret="marketly-eval-jwt-secret" \
  --from-literal=stripe-api-key="sk_test_eval_simulated" \
  --from-literal=redis-url="$REDIS_HOST:6379" \
  --from-literal=redis-password="$REDIS_PASS" \
  --dry-run=client -o yaml | kubectl apply -f -
echo "  secrets created"

# ---------------------------------------------------------------- phase 4
log "Phase 4/10: ingress-nginx (ClusterIP — traffic is in-cluster)"
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
helm repo update >/dev/null
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace marketly \
  --set controller.service.type=ClusterIP \
  --wait --timeout 300s
kubectl apply -f k8s/ingress.yaml
echo "  ingress ready"

# ---------------------------------------------------------------- phase 5
log "Phase 5/10: Argo CD + service sync"
helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
helm repo update >/dev/null
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --set server.service.type=ClusterIP \
  --wait --timeout 600s

# Git credentials for the (private) service repos.
for r in "${REPOS[@]}"; do
  kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: repo-$r
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: https://github.com/$ORG/$r
  username: x-access-token
  password: "$GITHUB_TOKEN"
EOF
done

kubectl apply -f helm/argocd-apps-eval.yaml

# Boot with ONE replica per service: the repo manifests say 3, and 27 service
# pods + Argo CD + Postgres + Redis + ingress on a single 7GB kind node is
# how run #1 starved. selfHeal is off, so this scale-down sticks; phase 6
# raises services to $REPLICAS once everything is healthy.
cap_replicas() {
  for d in $(kubectl -n marketly get deploy -o name 2>/dev/null); do
    case "$d" in
      */ingress-nginx-controller|*/postgres|*/redis) continue ;;
    esac
    cur=$(kubectl -n marketly get "$d" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 1)
    if [ "${cur:-1}" -gt 1 ] 2>/dev/null; then
      kubectl -n marketly scale "$d" --replicas=1 >/dev/null 2>&1 || true
    fi
  done
}
cap_replicas

dump_app_deep() {  # $1 = app name — pod states + waiting reasons + log tails
  echo "  ---- $1: pods ----"
  kubectl -n marketly get pods -l app="$1" -o \
    custom-columns=NAME:.metadata.name,PHASE:.status.phase,READY:.status.containerStatuses[0].ready,RESTARTS:.status.containerStatuses[0].restartCount,REASON:.status.containerStatuses[0].state.waiting.reason \
    2>/dev/null || echo "    (no pods)"
  for p in $(kubectl -n marketly get pods -l app="$1" -o name 2>/dev/null); do
    echo "  ---- $1: last log lines of ${p##*/} ----"
    kubectl -n marketly logs "$p" --tail=40 2>&1 | sed 's/^/    /' || true
  done
}

echo "Waiting for Argo CD apps to sync + go healthy (up to 20 min)..."
DEADLINE=$((SECONDS + 1200))
NOT_READY="pending"
ITER=0
while [ $SECONDS -lt $DEADLINE ]; do
  cap_replicas
  NOT_READY=$(kubectl get applications -n argocd -o json | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    print("parse-error"); raise SystemExit
bad = []
for it in data.get("items", []):
    st = it.get("status", {})
    # Readiness gates on HEALTH only. cap_replicas scales every service
    # down to 1 during boot, which leaves apps permanently OutOfSync
    # (selfHeal is off so it sticks) — sync status must not gate the loop.
    if st.get("health", {}).get("status") != "Healthy":
        bad.append(it["metadata"]["name"])
print(" ".join(bad))
' || echo "error")
  if [ -z "$NOT_READY" ]; then
    echo "  all apps Synced + Healthy"
    break
  fi
  echo "  not ready yet (${NOT_READY})"
  ITER=$((ITER + 1))
  # Every ~60s: overall pod table + runner memory (OOM evidence)
  if [ $((ITER % 3)) -eq 0 ]; then
    echo "  [diag] runner memory: $(free -m | awk 'NR==2{printf "%s/%s MB used", $3, $2}')  disk: $(df -h / | awk 'NR==2{print $3 " used"}')"
    kubectl -n marketly get pods 2>/dev/null | awk 'NR>1{printf "    %-52s %-10s restarts=%s\n", $1, $3, $4}' | head -30
  fi
  # Every ~90s: deep dive each still-unhealthy app (pod reasons + logs)
  if [ $((ITER % 4)) -eq 0 ]; then
    for a in $NOT_READY; do
      [ "$a" = "parse-error" ] && continue
      dump_app_deep "$a"
    done
  fi
  sleep 20
done

if [ -n "$NOT_READY" ]; then
  HEALTHY=$(kubectl get applications -n argocd -o json | python3 -c '
import json, sys
data = json.load(sys.stdin)
print(sum(1 for it in data.get("items", []) if it.get("status", {}).get("health", {}).get("status") == "Healthy"))')
  echo "  WARNING: $HEALTHY/9 apps healthy after 20 min"
  # Full self-diagnosis: everything needed to explain a stuck app, both to
  # the console and to the artifacts bundle.
  {
    echo "===== pods -o wide (marketly) ====="
    kubectl -n marketly get pods -o wide 2>&1
    echo; echo "===== unhealthy events (last 5m, marketly) ====="
    kubectl -n marketly get events --sort-by=.lastTimestamp 2>&1 | tail -40
    echo; echo "===== node ====="
    kubectl describe node 2>&1 | sed -n '1,45p'
    echo; echo "===== argocd app health ====="
    kubectl get applications -n argocd -o \
      custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status 2>&1
    echo; echo "===== per-app deep ====="
    for a in $NOT_READY; do dump_app_deep "$a"; done
    echo; echo "===== runner resources ====="
    free -m; df -h / /var/lib/docker 2>&1 | head -6
  } | tee "$ART/phase5-stuck-diagnostics.txt"
  if [ "$HEALTHY" -lt 6 ]; then
    echo "FAIL: fewer than 6 apps healthy — harness issue (see diagnostics above)"
    exit 1
  fi
fi

# ---------------------------------------------------------------- phase 6
log "Phase 6/10: scaling services to $REPLICAS replica(s)"
for d in $(kubectl -n marketly get deploy -o name); do
  case "$d" in
    */postgres|*/redis|*ingress-nginx*) continue ;;
  esac
  kubectl -n marketly scale "$d" --replicas="$REPLICAS"
done
echo "  scaled (Argo selfHeal is off in the eval apps so this sticks)"

# ---------------------------------------------------------------- phase 7
log "Phase 7/10: Sentinel (chart 1.7.0, provider=groq)"
helm repo add sentinel https://karimzakzouk.github.io/sentinel/ 2>/dev/null || true
helm repo update >/dev/null
helm upgrade --install sentinel sentinel/sentinel \
  --namespace sentinel --create-namespace \
  --version 1.7.0 \
  --values helm/sentinel-values.yaml \
  --set sentinel.githubToken="$GITHUB_TOKEN" \
  --set sentinel.llm.apiKey="$GROQ_API_KEY" \
  --set sentinel.llm.provider=groq \
  --set sentinel.llm.fastModel="$FAST_MODEL" \
  --set sentinel.llm.frontierModel="$FRONTIER_MODEL" \
  --set sentinel.autoMerge.minSandboxLevel="$MIN_SANDBOX_LEVEL" \
  --wait --timeout 300s
echo "  sentinel installed"

# ---------------------------------------------------------------- phase 8
log "Phase 8/10: traffic + ${WAIT_MINUTES}m soak"
bash scripts/02-start-traffic.sh
kubectl apply -f k8s/eval/login-hammer.yaml

PF_PID=""
pf_start() {
  kubectl -n sentinel port-forward svc/sentinel 18000:8000 >/dev/null 2>&1 &
  PF_PID=$!
}
sentinel_get() {
  local body="" attempt
  for attempt in 1 2 3; do
    if body=$(curl -sf -H "Authorization: Bearer $SENTINEL_API_TOKEN" \
                   "http://localhost:18000$1" 2>/dev/null); then
      printf '%s' "$body"
      return 0
    fi
    [ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null || true
    pf_start
    sleep 3
  done
  return 1
}
trap '[ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null || true' EXIT
pf_start

print_incidents() {
  python3 -c '
import json, sys
try:
    inc = json.load(sys.stdin)
except Exception:
    print("  (unparseable incident JSON)"); raise SystemExit
for i in inc:
    svc = (i.get("cluster") or {}).get("service", "?")
    st = i.get("status", "?")
    rc = (i.get("state") or {}).get("root_cause") or {}
    conf = rc.get("confidence") or 0
    conf = conf if isinstance(conf, (int, float)) else 0
    stmt = (rc.get("statement") or "")[:70]
    print(f"  {svc:<22} {st:<14} conf={conf:>4.0%}  {stmt}")
print(f"  total incidents: {len(inc)}")'
}

SOAK_END=$((SECONDS + WAIT_MINUTES * 60))
NEXT_INC=$((SECONDS + 10))
NEXT_DIAG=$((SECONDS + 60))
while [ $SECONDS -lt $SOAK_END ]; do
  sleep 10
  if [ $SECONDS -ge $NEXT_INC ]; then
    NEXT_INC=$((SECONDS + 300))
    LEFT=$(( (SOAK_END - SECONDS + 59) / 60 ))
    echo "--- soak: ${LEFT}m remaining ---"
    if sentinel_get "/incidents?limit=50" > "$ART/incidents.json"; then
      python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$ART/incidents.json" 2>/dev/null \
        && cat "$ART/incidents.json" | print_incidents \
        || echo "  (no incidents yet)"
    else
      echo "  (sentinel API unreachable — will retry)"
    fi
  fi
  if [ $SECONDS -ge $NEXT_DIAG ]; then
    NEXT_DIAG=$((SECONDS + 900))
    T=$((SECONDS / 60))
    kubectl get pods -n marketly > "$ART/pods-t${T}m.txt" 2>&1 || true
    kubectl -n sentinel logs -l app.kubernetes.io/name=sentinel --tail=100 \
      > "$ART/sentinel-log-t${T}m.txt" 2>&1 || true
  fi
done

# ---------------------------------------------------------------- phase 9
log "Phase 9/10: results"
if sentinel_get "/incidents?limit=50" > "$ART/incidents.json"; then
  cat "$ART/incidents.json" | print_incidents || true
fi
kubectl get pods -n marketly > "$ART/pods-final.txt" 2>&1 || true
kubectl get applications -n argocd > "$ART/argocd-apps-final.txt" 2>&1 || true
kubectl -n sentinel logs -l app.kubernetes.io/name=sentinel --tail=1000 \
  > "$ART/sentinel-log-final.txt" 2>&1 || true

echo
echo "PR verification (scripts/04-verify-prs.sh):"
GITHUB_TOKEN="$GITHUB_TOKEN" bash scripts/04-verify-prs.sh \
  | tee "$ART/pr-verification.txt" || true

echo
echo "Recovery verification (scripts/05-verify-recovery.sh):"
bash scripts/05-verify-recovery.sh | tee "$ART/recovery.txt" || true

# Structured score + step summary
GITHUB_TOKEN="$GITHUB_TOKEN" python3 scripts/eval-score.py "$ART" \
  && cat "$ART/score.md" >> "${GITHUB_STEP_SUMMARY:-/dev/stdout}" || true

# ---------------------------------------------------------------- phase 10
if [ "$RESET_REPOS" = "true" ]; then
  log "Phase 10/10: resetting service repos to pre-eval SHAs"
  GITHUB_TOKEN="$GITHUB_TOKEN" python3 scripts/eval-reset.py "$ART" || true
else
  log "Phase 10/10: reset skipped (RESET_REPOS != true)"
fi

# ---------------------------------------------------------------- verdict
TOTAL=$(python3 -c '
import json
try:
    print(len(json.load(open("'"$ART"'/incidents.json"))))
except Exception:
    print(0)')
if [ "$TOTAL" -eq 0 ]; then
  echo
  echo "FAIL: zero incidents detected — the harness is broken, this is not a score."
  exit 1
fi
echo
echo "Eval complete. Score is in the job summary; raw data in artifacts."
