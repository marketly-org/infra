#!/bin/bash
# 02-start-traffic.sh — deploys a traffic generator that hits all endpoints.
#
# IMPORTANT (2026-09-23 eval post-mortem): the marketly ingress rewrites
# the service prefix away (/search -> /, /auth/login -> /login), but the
# services serve their own prefixes (search-api routes /search, user-api
# routes /auth/login, checkout-api routes /checkout). Going through the
# ingress 404s every request, which is why run #4 saw zero incidents.
# The generator therefore talks to the services directly via cluster DNS.
#
# IMPORTANT (run #7 post-mortem, 2026-09-23): payloads must actually reach
# the planted bugs:
#   - shipping-api /quote needs fromZip+toZip+weightKg to pass bean
#     validation; the old {address,items} payload died at @Valid with a
#     400 and the carrier Optional.get() NPE was unreachable.
#   - /auth/login needs a REGISTERED user; the old payload used
#     test@example.com which was never registered -> 401 -> zero refresh
#     tokens issued -> user-api's leak never grew.
#   - inventory-api's SELECT-then-UPDATE race needs burst concurrency at
#     the availability boundary; one reserve per 0.5s never overlaps.
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
    #!/bin/sh
    # Register the traffic users once (every successful login afterwards
    # issues a NEW refresh token into user-api's unbounded Map — the leak).
    for i in 1 2 3 4; do
      curl -sf -X POST "http://user-api.${NS}:8080/auth/register" \\
        -H "Content-Type: application/json" \\
        -d "{\"email\":\"traffic-\$i@example.com\",\"password\":\"test-password\",\"name\":\"Traffic \$i\"}" || true
    done

    # Steady-state loop: one pass over every service.
    worker() {
      id=\$1
      while true; do
        # search-api: missing q -> params.q.unwrap() panics (Rust)
        curl -sf "http://search-api.${NS}:8080/search" || true
        curl -sf "http://search-api.${NS}:8080/search?q=laptop" || true
        # inventory-api: list (the oversell bug shows up here as negative
        # availability once the race has fired)
        curl -sf "http://inventory-api.${NS}:8080/products" || true
        curl -sf -X POST "http://inventory-api.${NS}:8080/reserve" \\
          -H "Content-Type: application/json" \\
          -d '{"sku":"WIDGET-001","quantity":1}' || true
        # user-api: successful logins grow the unbounded refresh-token Map
        curl -sf -X POST "http://user-api.${NS}:8080/auth/login" \\
          -H "Content-Type: application/json" \\
          -d "{\"email\":\"traffic-\$id@example.com\",\"password\":\"test-password\"}" || true
        # shipping-api: VALID quote request (fromZip/toZip/weightKg pass
        # @Valid) -> carrier call fails (no carrier host) -> Optional.get()
        # -> NoSuchElementException. The old invalid payload never got
        # past validation.
        curl -sf -X POST "http://shipping-api.${NS}:8080/quote" \\
          -H "Content-Type: application/json" \\
          -d '{"fromZip":"94105","toZip":"10001","weightKg":2.5}' || true
        # checkout-api: full chain (inventory -> shipping -> payments)
        curl -sf -X POST "http://checkout-api.${NS}:8080/checkout" \\
          -H "Content-Type: application/json" \\
          -d '{"customer_email":"test@example.com","items":[{"sku":"WIDGET-001","quantity":1}],"shipping_address":"123 Main St"}' || true
        # payments-api: direct charges (the fake stripe key fails them;
        # kept so the payments path stays warm). Run #28 post-mortem: the
        # planted bug is the missing IdempotencyKey — a RETRY of the same
        # order double-charges — but unique order_ids meant that path
        # never fired. Reuse a rotating order_id pool so the same order
        # is charged repeatedly.
        curl -sf -X POST "http://payments-api.${NS}:8080/charge" \\
          -H "Content-Type: application/json" \\
          -d "{\"order_id\":\"ord-eval-dup-\$(( \$(date +%s) % 8 ))\",\"customer_email\":\"test@example.com\",\"amount_cents\":1999,\"currency\":\"usd\"}" || true
        sleep 0.5
      done
    }

    # Race loop: the inventory oversell bug (SELECT then UPDATE, no
    # transaction) only fires when several reserves for the same SKU
    # overlap at the availability boundary. Run #28: 3-wide bursts
    # every 3s never overlapped at the boundary — fire 6-wide bursts
    # every 1s on a rotating SKU. Availability is replenished by the eval
    # driver's periodic \`UPDATE products SET reserved=0\`.
    # NOTE: busybox ash — no arrays, no bashisms.
    racer() {
      i=0
      while true; do
        case \$((i % 3)) in
          0) sku=GADGET-001 ;;
          1) sku=GIZMO-001 ;;
          2) sku=WIDGET-001 ;;
        esac
        i=\$((i + 1))
        for b in 1 2 3 4 5 6; do
          curl -sf -X POST "http://inventory-api.${NS}:8080/reserve" \\
            -H "Content-Type: application/json" \\
            -d "{\"sku\":\"\$sku\",\"quantity\":1}" || true &
        done
        wait
        sleep 1
      done
    }

    worker a &
    worker b &
    racer &
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
              memory: 128Mi
      volumes:
        - name: script
          configMap:
            name: traffic-gen-script
            defaultMode: 0755
EOF

echo "  ✓ traffic generator deployed (direct service DNS, valid payloads, inventory race bursts)"
echo ""
echo "Traffic is now hitting all endpoints via cluster DNS."
echo "Workers get their jobs from scripts/06-start-job-traffic.sh."
