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
#   6.5. Environment tuning (cap user-api heap so the leak OOMs in-window)
#   7. Install Sentinel (chart $SENTINEL_CHART_VERSION) with Groq + GitHub token
#   8. Start traffic + soak for $WAIT_MINUTES, snapshotting state
#   9. Score Sentinel's PRs vs ground truth, write step summary + artifacts
#  10. Reset service repos to pre-eval SHAs (default on)
#
# Required env:
#   GITHUB_TOKEN  PAT with repo + read:packages on marketly-org
#   LLM_PROVIDER  groq | gemini | cerebras
#   <PROVIDER>_API_KEY  the matching key (GROQ_API_KEY / GEMINI_API_KEY /
#                       CEREBRAS_API_KEY)
# Optional env (defaults):
#   WAIT_MINUTES=45  REPLICAS=2  MIN_SANDBOX_LEVEL=3  RESET_REPOS=true
#   FAST_MODEL / FRONTIER_MODEL  per-provider defaults below
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
# Default provider: GROQ (reverted 2026-09-24 after run #13). Head-to-head
# on the same incident set: Groq (run #12) shipped 4/9 PRs; Gemini free tier
# (run #13) shipped 1/9 — its 20-RPM bucket starved 6/7 concurrent fix
# proposers until their 5-min context deadlines blew (attempts 4/5/6 failed
# in 2ms each). Groq's TPM waits are slower per-call but its aggregate
# throughput under 7 parallel investigations wins. Gemini stays available
# via LLM_PROVIDER=gemini.
LLM_PROVIDER="${LLM_PROVIDER:-groq}"
case "$LLM_PROVIDER" in
  gemini)
    # Round-3 bench (2026-09-24): 3.1/3.5/3.8-flash + gemma-4 all 503/500
    # "high demand" on the free tier; 2.5-flash is 5/5+5/5 on the run-#12
    # incident prompts and reliable. Run #13 measured the free-tier quota:
    # generate_content_free_tier_requests limit=20/min for 2.5-flash. 20 RPM
    # is NOT enough for 7 concurrent incident pipelines — only the first
    # fix proposal survives; the rest die on context deadlines.
    FAST_MODEL="${FAST_MODEL:-gemini-2.5-flash}"
    FRONTIER_MODEL="${FRONTIER_MODEL:-gemini-2.5-flash}" ;;
  groq)
    # Run #12 config: 4/9 PRs, best free-tier result so far. gpt-oss-120b
    # TPM waits killed checkout-api's fix proposer once (context deadline),
    # but 6/7 pipelines still completed vs Gemini's 1/7 in run #13.
    FAST_MODEL="${FAST_MODEL:-openai/gpt-oss-20b}"
    FRONTIER_MODEL="${FRONTIER_MODEL:-openai/gpt-oss-120b}" ;;
  cerebras)
    FAST_MODEL="${FAST_MODEL:-qwen-3.8-27b}"
    FRONTIER_MODEL="${FRONTIER_MODEL:-gpt-oss-120b}" ;;
  *) echo "ERROR: unknown LLM_PROVIDER '$LLM_PROVIDER'"; exit 1 ;;
esac
SENTINEL_CHART_VERSION="${SENTINEL_CHART_VERSION:-1.7.4}"
SENTINEL_API_TOKEN="marketly-sentinel-token"

# Guard rails
WAIT_MINUTES=$(( WAIT_MINUTES > 240 ? 240 : WAIT_MINUTES ))

: "${GITHUB_TOKEN:?Set GITHUB_TOKEN to a PAT with repo + read:packages on marketly-org}"
case "$LLM_PROVIDER" in
  gemini)   : "${GEMINI_API_KEY:?Set GEMINI_API_KEY (LLM_PROVIDER=gemini)}" ;;
  groq)     : "${GROQ_API_KEY:?Set GROQ_API_KEY (LLM_PROVIDER=groq)}" ;;
  cerebras) : "${CEREBRAS_API_KEY:?Set CEREBRAS_API_KEY (LLM_PROVIDER=cerebras)}" ;;
esac

mkdir -p "$ART"

# Timestamp of run start — eval-score.py / 04-verify-prs.sh only count
# Sentinel PRs created after this moment. A stale PR from an earlier run
# must never inflate the score (the 2026-09-23 run scored 5/9 on year-old
# leftover PRs during a zero-incident soak).
export EVAL_RUN_START
EVAL_RUN_START="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "Eval run started at $EVAL_RUN_START (stale-PR cutoff)"

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

# ---------------------------------------------------------------- phase 6.5
log "Phase 6.5/10: environment tuning (accelerate the memory-leak bug)"
# Run #7 post-mortem: user-api's token Map grows ~400B per login. At the
# hammer's ~160 logins/s that is ~64MB in 7 minutes — invisible against
# Node's cgroup-defaulted ~128MB heap (container limit 256Mi). Cap the
# heap so the planted leak reaches the heap limit inside the soak window
# and produces the ground-truth `FATAL ERROR: Ineffective mark-compacts`
# (plus a restart, which the pod-status detector sees).
# This patches ENVIRONMENT (a standard ops knob), not the bug: the leak,
# the code, and the fix Sentinel must produce are unchanged.
kubectl -n marketly set env deploy/user-api NODE_OPTIONS="--max-old-space-size=64"
kubectl -n marketly rollout status deploy/user-api --timeout=240s
echo "  user-api heap capped at 64MB (NODE_OPTIONS)"
# Run #11 post-mortem: with the cap, user-api died of pg connection
# timeouts (event-loop lag starved pg's 2s connect timeout) before the
# FATAL heap line, and the investigation misdiagnosed a DB-config bug.
# The cap STAYS at 64MB: filling the heap faster than the soak window
# matters more than which signature wins the race, and v1.7.4's runtime
# context now shows the LLM both NODE_OPTIONS=--max-old-space-size=64
# and USER_DATABASE_URL — so even a pg-timeout crash can be diagnosed
# correctly (heap pressure -> connection timeouts) instead of guessed at
# (canonical-var hallucination).

# ---------------------------------------------------------------- phase 6.6
log "Phase 6.6/10: checkout slow-sink (trigger the pool/event-loop bug)"
# Run #7/#10/#11 post-mortem: checkout's planted bug (httpx.Client() with
# no timeout= in app/clients.py) needs a SLOW downstream to fire. With
# everything fast-409ing, the bug never exercised and Sentinel instead
# misdiagnosed the 409 noise. This deploys an 8-second slow inventory
# stand-in and points checkout's CHECKOUT_INVENTORY_API_URL at it:
# the sync httpx call inside the async handler blocks the event loop,
# /health stops responding, the liveness probe (period 10s) fails 3x,
# and the container restarts — a signal the pod-status detector sees.
# The ground-truth fix (explicit httpx timeout) is now behaviorally
# verifiable: with the fix, checkout fails fast and /health stays live.
kubectl -n marketly apply -f - <<'SLOWSINK'
apiVersion: v1
kind: ConfigMap
metadata:
  name: slow-inventory-script
  namespace: marketly
data:
  slow.py: |
    import json, time
    from http.server import BaseHTTPRequestHandler, HTTPServer
    class H(BaseHTTPRequestHandler):
        def _slow(self):
            time.sleep(8)
            body = json.dumps({"sku": "WIDGET-001", "price_cents": 999,
                               "stock": 100, "reserved": 0}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        def do_GET(self): self._slow()
        def do_POST(self): self._slow()
        def log_message(self, *a): pass
    HTTPServer(("0.0.0.0", 8080), H).serve_forever()
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: slow-inventory
  namespace: marketly
  labels:
    app.kubernetes.io/name: slow-inventory
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: slow-inventory
  template:
    metadata:
      labels:
        app.kubernetes.io/name: slow-inventory
    spec:
      containers:
        - name: slow
          image: python:3.12-slim
          command: ["python", "/scripts/slow.py"]
          ports:
            - containerPort: 8080
          resources:
            requests: {cpu: 50m, memory: 32Mi}
            limits: {cpu: 500m, memory: 64Mi}
          volumeMounts:
            - name: script
              mountPath: /scripts
      volumes:
        - name: script
          configMap:
            name: slow-inventory-script
---
apiVersion: v1
kind: Service
metadata:
  name: slow-inventory
  namespace: marketly
spec:
  selector:
    app.kubernetes.io/name: slow-inventory
  ports:
    - port: 8080
      targetPort: 8080
SLOWSINK
kubectl -n marketly rollout status deploy/slow-inventory --timeout=240s
kubectl -n marketly set env deploy/checkout-api \
  CHECKOUT_INVENTORY_API_URL="http://slow-inventory.marketly.svc.cluster.local:8080"
kubectl -n marketly rollout status deploy/checkout-api --timeout=240s
echo "  checkout-api now routed through the 8s slow sink (bug will fire:"
echo "  event-loop freeze -> liveness failures -> restarts)"

# ---------------------------------------------------------------- phase 7
log "Phase 7/10: Sentinel (chart $SENTINEL_CHART_VERSION, provider=$LLM_PROVIDER)"

case "$LLM_PROVIDER" in
  gemini)   LLM_API_KEY="$GEMINI_API_KEY" ;;
  groq)     LLM_API_KEY="$GROQ_API_KEY" ;;
  cerebras) LLM_API_KEY="$CEREBRAS_API_KEY" ;;
esac

# Fail fast if the configured models no longer exist or do not respond (run
# 35890547218 lost a full 40-min eval to a deprecated model name: every
# investigation died at round 1 with "model does not exist").
echo "  validating $LLM_PROVIDER models (frontier=$FRONTIER_MODEL fast=$FAST_MODEL)..."
case "$LLM_PROVIDER" in
  gemini)
    # Native v1beta endpoint — the exact URL + auth goai's google provider
    # uses in production (the OpenAI-compat path is NOT used for gemini).
    # Lists models, then smoke-tests each configured model with a tiny
    # generateContent call (catches 503 "high demand" and 404 deprecations
    # that listing alone misses).
    MODELS_JSON=$(curl -s -m 30 \
      "https://generativelanguage.googleapis.com/v1beta/models?pageSize=100&key=$LLM_API_KEY")
    MODELS_LIST=$(printf '%s' "$MODELS_JSON" | python3 -c '
import json, sys
try:
    print("\n".join(m["name"].removeprefix("models/") for m in json.load(sys.stdin).get("models", [])))
except Exception:
    print("")')
    if [ -z "$MODELS_LIST" ]; then
      echo "  ERROR: could not list Gemini models. Raw response:"
      printf '%s\n' "$MODELS_JSON" | head -c 500; echo
      exit 1
    fi
    for M in "$FRONTIER_MODEL" "$FAST_MODEL"; do
      if ! echo "$MODELS_LIST" | grep -qx "$M"; then
        echo "  FAIL: model '$M' is not available to this key (deprecated? renamed?)"
        echo "  Available: $(echo "$MODELS_LIST" | tr '\n' ' ')"
        exit 1
      fi
    done
    echo "  both models listed; smoke-testing generateContent..."
    for M in "$FRONTIER_MODEL" "$FAST_MODEL"; do
      SMOKE_CODE=$(curl -s -o /tmp/gemini-smoke.json -w '%{http_code}' -m 60 \
        "https://generativelanguage.googleapis.com/v1beta/models/$M:generateContent?key=$LLM_API_KEY" \
        -H 'Content-Type: application/json' \
        -d '{"contents":[{"parts":[{"text":"Reply with the single word OK"}]}],"generationConfig":{"maxOutputTokens":512}}')
      if [ "$SMOKE_CODE" != "200" ]; then
        echo "  FAIL: $M smoke test HTTP $SMOKE_CODE:"
        head -c 400 /tmp/gemini-smoke.json; echo
        exit 1
      fi
    done
    echo "  both models respond"
    ;;
  groq)
    MODELS_JSON=$(curl -s -H "Authorization: Bearer $LLM_API_KEY" \
      https://api.groq.com/openai/v1/models)
    MODELS_LIST=$(printf '%s' "$MODELS_JSON" | python3 -c '
import json, sys
try:
    print("\n".join(m["id"] for m in json.load(sys.stdin).get("data", [])))
except Exception:
    print("")')
    if [ -z "$MODELS_LIST" ]; then
      echo "  ERROR: could not list Groq models. Raw response:"
      printf '%s\n' "$MODELS_JSON" | head -c 500; echo
      exit 1
    fi
    echo "  available: $(echo "$MODELS_LIST" | tr '\n' ' ')"
    for M in "$FRONTIER_MODEL" "$FAST_MODEL"; do
      if ! echo "$MODELS_LIST" | grep -qx "$M"; then
        echo "  FAIL: model '$M' is not available to this key (deprecated? renamed?)"
        echo "  Pick from the list above and re-dispatch with fast_model/frontier_model inputs."
        exit 1
      fi
    done
    echo "  both models available"
    ;;
  cerebras)
    # Cloudflare error-1010s non-browser user agents, so identify as one.
    MODELS_JSON=$(curl -s -m 30 -A 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36' \
      -H "Authorization: Bearer $LLM_API_KEY" https://api.cerebras.ai/v1/models)
    MODELS_LIST=$(printf '%s' "$MODELS_JSON" | python3 -c '
import json, sys
try:
    print("\n".join(m["id"] for m in json.load(sys.stdin).get("data", [])))
except Exception:
    print("")')
    if [ -z "$MODELS_LIST" ]; then
      echo "  ERROR: could not list Cerebras models. Raw response:"
      printf '%s\n' "$MODELS_JSON" | head -c 500; echo
      exit 1
    fi
    echo "  available: $(echo "$MODELS_LIST" | tr '\n' ' ')"
    for M in "$FRONTIER_MODEL" "$FAST_MODEL"; do
      if ! echo "$MODELS_LIST" | grep -qx "$M"; then
        echo "  FAIL: model '$M' is not available to this key"
        exit 1
      fi
    done
    echo "  both models available"
    ;;
esac

helm repo add sentinel https://karimzakzouk.github.io/sentinel/ 2>/dev/null || true
helm repo update >/dev/null
# --- LLM failover pool (chart 1.7.4: SENTINEL_LLM_PROVIDERS) ---------------
# Stacks a second provider as overflow for the primary. When the primary
# hard-fails a call (retries exhausted — e.g. Groq TPM starvation under 5+
# concurrent fix proposals, which killed checkout-api in runs #12 and #14),
# the pool's circuit breaker fails over instead of sleeping out the window.
# The primary is whoever LLM_PROVIDER names; the overflow is the other free
# key when we hold one. Provider entries carry their own models.
PROVIDERS_SET_JSON=""
PROVIDERS_SETS=()
OVERFLOW_KEY=""
OVERFLOW_MODELS=""
case "$LLM_PROVIDER" in
  groq)
    if [ -n "${GEMINI_API_KEY:-}" ]; then
      OVERFLOW_KEY="$GEMINI_API_KEY"; OVERFLOW_MODELS='"fastModel":"gemini-2.5-flash","frontierModel":"gemini-2.5-flash"'
    fi ;;
  gemini)
    if [ -n "${GROQ_API_KEY:-}" ]; then
      OVERFLOW_KEY="$GROQ_API_KEY"; OVERFLOW_MODELS='"fastModel":"openai/gpt-oss-20b","frontierModel":"openai/gpt-oss-120b"'
    fi ;;
esac
if [ -n "$OVERFLOW_KEY" ]; then
  OVERFLOW_PROVIDER="$([ "$LLM_PROVIDER" = groq ] && echo gemini || echo groq)"
  PROVIDERS_SET_JSON="[{\"id\":\"primary\",\"provider\":\"$LLM_PROVIDER\",\"apiKey\":\"$LLM_API_KEY\",\"fastModel\":\"$FAST_MODEL\",\"frontierModel\":\"$FRONTIER_MODEL\",\"priority\":1},{\"id\":\"overflow\",\"provider\":\"$OVERFLOW_PROVIDER\",\"apiKey\":\"$OVERFLOW_KEY\",$OVERFLOW_MODELS,\"priority\":2}]"
  # MUST go through an array: in an unquoted ${var:+word} the double quotes
  # around the value are parsed as shell quote OPERATORS, splitting the
  # flag into three argv pieces — helm then receives
  # `sentinel.llm.providers=` with an EMPTY value, silently sets it to nil,
  # and the pod boots in single-provider mode (run #15: pool "configured",
  # log said disabled, checkout-api died on TPM for the third time).
  PROVIDERS_SETS+=(--set-json "sentinel.llm.providers=$PROVIDERS_SET_JSON")
  echo "  llm pool: $LLM_PROVIDER (primary) + $OVERFLOW_PROVIDER (overflow)"
fi

# --- Sandbox (Kaniko) registry auth -----------------------------------------
# Canary images go to the PROD registry by design (kaniko.go: any image
# name containing "/" is used as-is, so the prod namespace's pull secrets
# cover the canary too). Our services live on ghcr.io/marketly-org/*, so
# the registry auth must be for GHCR — a GitHub PAT with write:packages,
# not Docker Hub creds (run #15 failed here: Kaniko pushed canaries to
# ghcr.io with docker.io creds -> UNAUTHORIZED on every build).
# The chart's single auth slot (dockerHubUsername/dockerHubToken +
# kanikoRegistry) is overloaded: registry=ghcr.io + PAT password.
SANDBOX_SETS=()
GH_USER=$(curl -s -m 15 -H "Authorization: token $GITHUB_TOKEN" https://api.github.com/user \
  | jq -r '.login // empty' 2>/dev/null || true)
if [ -n "$GH_USER" ]; then
  SANDBOX_SETS+=(--set-string "sentinel.kanikoRegistry=ghcr.io"
                 --set-string "sentinel.dockerHubUsername=$GH_USER"
                 --set-string "sentinel.dockerHubToken=$GITHUB_TOKEN")
  echo "  sandbox: Kaniko pushes -> ghcr.io as $GH_USER"
else
  echo "  sandbox: could not resolve GH user — Kaniko pushes will fail (auto-merge gate 3 closed)"
fi

helm upgrade --install sentinel sentinel/sentinel \
  --namespace sentinel --create-namespace \
  --version "$SENTINEL_CHART_VERSION" \
  --values helm/sentinel-values.yaml \
  --set sentinel.githubToken="$GITHUB_TOKEN" \
  --set sentinel.llm.apiKey="$LLM_API_KEY" \
  --set sentinel.llm.provider="$LLM_PROVIDER" \
  --set sentinel.llm.fastModel="$FAST_MODEL" \
  --set sentinel.llm.frontierModel="$FRONTIER_MODEL" \
  --set sentinel.autoMerge.minSandboxLevel="$MIN_SANDBOX_LEVEL" \
  "${PROVIDERS_SETS[@]}" \
  "${SANDBOX_SETS[@]}" \
  --wait --timeout 300s
echo "  sentinel installed"

# The chart has no knobs for the pipeline deadlines (as of 1.7.4), so they
# are patched in post-install. Run #14 post-mortem: 5 concurrent gpt-oss-120b
# fix proposals drained Groq's TPM; the LAST proposer in line (checkout-api,
# 2/2 runs) exhausted its 5-min context budget while waiting on rate-limit
# windows — attempts 4/5/6 failed in ~2ms each. The investigation timeout is
# the parent budget, so it must rise too (fix-proposer ctx derives from it).
kubectl -n sentinel set env deploy/sentinel \
  SENTINEL_FIX_PROPOSER_TIMEOUT="${SENTINEL_FIX_PROPOSER_TIMEOUT:-900}" \
  SENTINEL_INVESTIGATION_TIMEOUT="${SENTINEL_INVESTIGATION_TIMEOUT:-1200}"
kubectl -n sentinel rollout status deploy/sentinel --timeout=180s
echo "  sentinel deadlines: fix-proposer 900s, investigation 1200s"

# ---------------------------------------------------------------- phase 8
log "Phase 8/10: traffic + ${WAIT_MINUTES}m soak"
bash scripts/02-start-traffic.sh
kubectl apply -f k8s/eval/login-hammer.yaml
# Worker-queue + gRPC injectors: Sidekiq orders/payments (analytics deadlock),
# Celery notifications (SMTP failures), gRPC recommend+append (segfault race).
bash scripts/06-start-job-traffic.sh

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
    inc = json.load(sys.stdin) or []   # empty list marshals as JSON null
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
NEXT_RESTOCK=$((SECONDS + 45))
while [ $SECONDS -lt $SOAK_END ]; do
  sleep 10
  # Replenish inventory availability every 60s: reserve-only traffic
  # burns reserved capacity to zero in ~1 minute, after which everything
  # 409s and (a) checkout's chain stalls at reserve and (b) the oversell
  # race never gets another boundary to fire on.
  if [ $SECONDS -ge $NEXT_RESTOCK ]; then
    NEXT_RESTOCK=$((SECONDS + 45))
    kubectl -n marketly exec deploy/postgres -- env PGPASSWORD=marketly-eval \
      psql -U marketly -d inventory -c "UPDATE products SET reserved = 0" >/dev/null 2>&1 || true
  fi
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

# Per-service + injector log tails: shows whether the planted bugs actually
# produced their failure signatures (SMTP refusals, segfault, deadlock,
# NoSuchElementException) even when the detector missed them.
for D in checkout-api payments-api inventory-api user-api search-api \
         shipping-api analytics-worker notification-worker \
         recommendation-engine traffic-gen login-hammer \
         sidekiq-injector celery-injector grpc-injector; do
  kubectl -n marketly logs "deploy/$D" --tail=80 \
    > "$ART/svclog-$D.txt" 2>&1 || true
done

# Bug-fired signature matrix: did each planted bug actually produce its
# failure signature during the soak? Run #7 scored 1/9 detection, but the
# artifacts later showed 7 of the bugs had never fired at all — without
# this matrix, "Sentinel missed it" and "harness never triggered it" look
# identical in the score table.
{
  echo "=== Bug-fired signature matrix (from svclog tails) ==="
  printf "%-24s %-8s %s\n" "SERVICE" "FIRED?" "SIGNATURE"
  printf "%-24s %-8s %s\n" "-------" "-----" "---------"
  declare -A SIG=(
    [payments-api]="rate_limited"
    [inventory-api]="index out of range"
    [user-api]="Ineffective mark-compacts|FATAL ERROR"
    [search-api]="panicked at"
    [shipping-api]="NoSuchElementException"
    [analytics-worker]="could not acquire lock|deadlock|NoMethodError"
    [notification-worker]="send_email.failed|gaierror"
    [recommendation-engine]="Segmentation fault|SIGSEGV"
  )
  for D in payments-api inventory-api user-api search-api \
           shipping-api analytics-worker notification-worker recommendation-engine; do
    PAT="${SIG[$D]}"
    if grep -qE "$PAT" "$ART/svclog-$D.txt" 2>/dev/null; then
      printf "%-24s %-8s %s\n" "$D" "YES" "$PAT"
    else
      printf "%-24s %-8s %s\n" "$D" "no" "$PAT"
    fi
  done
  # checkout-api: with the slow sink (phase 6.6) the signature is NOT a
  # log line — the frozen event loop stops logging entirely. The bug's
  # observable effect is liveness-probe failures -> container restarts,
  # which is exactly what the pod-status detector watches for.
  CHECKOUT_RESTARTS=$(kubectl -n marketly get pods -l app=checkout-api \
    -o jsonpath='{.items[*].status.containerStatuses[*].restartCount}' 2>/dev/null || echo "")
  CHECKOUT_MAX=0
  for R in $CHECKOUT_RESTARTS; do
    [ "$R" -gt "$CHECKOUT_MAX" ] 2>/dev/null && CHECKOUT_MAX=$R
  done
  if [ "$CHECKOUT_MAX" -gt 0 ] 2>/dev/null; then
    echo "checkout-api            YES      event-loop freeze -> liveness restarts (max restartCount=$CHECKOUT_MAX)"
  else
    echo "checkout-api            no       expected: liveness restarts via slow sink (none observed)"
  fi
  # Silent-bug check: inventory oversell leaves no log and no crash — the
  # only evidence is reserved > stock in the DB.
  OVERSOLD=$(kubectl -n marketly exec deploy/postgres -- env PGPASSWORD=marketly-eval \
    psql -U marketly -d inventory -tAc \
    "SELECT count(*) FROM products WHERE reserved > stock" 2>/dev/null || echo "")
  if [ "${OVERSOLD:-0}" -gt 0 ] 2>/dev/null; then
    echo "inventory-api           OVERSOLD  reserved > stock on $OVERSOLD product(s) — silent bug FIRED"
  else
    echo "inventory-api           -        (oversell not observed: reserved <= stock)"
  fi
} | tee "$ART/bug-fired-matrix.txt"

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
    print(len(json.load(open("'"$ART"'/incidents.json")) or []))  # null = 0
except Exception:
    print(0)')
if [ "$TOTAL" -eq 0 ]; then
  echo
  echo "FAIL: zero incidents detected — the harness is broken, this is not a score."
  exit 1
fi
echo
echo "Eval complete. Score is in the job summary; raw data in artifacts."
