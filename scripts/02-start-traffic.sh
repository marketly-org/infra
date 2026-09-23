#!/bin/bash
# 02-start-traffic.sh — deploys a traffic generator that hits all endpoints.
#
# IMPORTANT (2026-09-23 eval post-mortem): the marketly ingress rewrites
# the service prefix away (/search -> /, /auth/login -> /login), but the
# services serve their own prefixes (search-api routes /search, user-api
# routes /auth/login, checkout-api routes /checkout). Going through the
# ingress 404s every request, which is why run #4 saw zero incidents.
# The generator therefore talks to the services directly via cluster DNS.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Deploying traffic generator ==="

NS=marketly.svc.cluster.local

# Deploy a traffic generator pod
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: traffic-gen-script
  namespace: marketly
data:
  run.sh: |
    #!/bin/bash
    # Two parallel loops: the second one exists to create concurrent
    # inventory reserve/confirm traffic (the SELECT-then-UPDATE race
    # needs overlapping requests to manifest).
    worker() {
      local id=\$1
      while true; do
        # search-api: missing q -> params.q.unwrap() panics (Rust)
        curl -sf "http://search-api.${NS}:8080/search" || true
        curl -sf "http://search-api.${NS}:8080/search?q=laptop" || true
        # inventory-api: list + reserve (race needs concurrency)
        curl -sf "http://inventory-api.${NS}:8080/products" || true
        curl -sf -X POST "http://inventory-api.${NS}:8080/reserve" \\
          -H "Content-Type: application/json" \\
          -d '{"sku":"WIDGET-001","quantity":1}' || true
        # user-api: successful logins grow the unbounded refresh-token Map
        curl -sf -X POST "http://user-api.${NS}:8080/auth/login" \\
          -H "Content-Type: application/json" \\
          -d '{"email":"test'"'"'\$id'"'"'@example.com","password":"test-password"}' || true
        # shipping-api: no to_zip -> NoSuchElementException (Java)
        curl -sf -X POST "http://shipping-api.${NS}:8080/quote" \\
          -H "Content-Type: application/json" \\
          -d '{"address":"123 Main St","items":[{"sku":"WIDGET-001","quantity":1}]}' || true
        # checkout-api: full chain (inventory -> shipping -> payments)
        curl -sf -X POST "http://checkout-api.${NS}:8080/checkout" \\
          -H "Content-Type: application/json" \\
          -d '{"customer_email":"test@example.com","items":[{"sku":"WIDGET-001","quantity":1}],"shipping_address":"123 Main St"}' || true
        # payments-api: direct charges (double-charge on repeated order_id
        # is the idempotency bug; charges with the simulated Stripe key
        # also exercise the payment path independent of checkout)
        curl -sf -X POST "http://payments-api.${NS}:8080/charge" \\
          -H "Content-Type: application/json" \\
          -d '{"order_id":"ord-eval-'"'"'\$id'"'"'-'"'"'\$(date +%s)"'"'"'","customer_email":"test@example.com","amount_cents":1999,"currency":"usd"}' || true
        sleep 0.5
      done
    }
    worker a &
    worker b &
    wait
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: traffic-gen
  namespace: marketly
spec:
  replicas: 1
  selector:
    matchLabels:
      app: traffic-gen
  template:
    metadata:
      labels:
        app: traffic-gen
    spec:
      containers:
        - name: traffic-gen
          image: curlimages/curl:8.10.1
          command: ["/bin/sh", "/scripts/run.sh"]
          volumeMounts:
            - name: script
              mountPath: /scripts
          resources:
            requests:
              cpu: 50m
              memory: 32Mi
            limits:
              cpu: 300m
              memory: 64Mi
      volumes:
        - name: script
          configMap:
            name: traffic-gen-script
            defaultMode: 0755
EOF

echo "  ✓ traffic generator deployed (direct service DNS, correct routes)"
echo ""
echo "Traffic is now hitting all endpoints via cluster DNS."
echo "Workers get their jobs from scripts/06-start-job-traffic.sh."
