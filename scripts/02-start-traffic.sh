#!/bin/bash
# 02-start-traffic.sh — deploys a traffic generator that hits all endpoints.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Deploying traffic generator ==="

# Get the ingress IP
INGRESS_IP=$(kubectl -n marketly get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
if [ -z "$INGRESS_IP" ]; then
  echo "WARNING: ingress IP not ready yet — using port-forward instead"
  INGRESS_IP="localhost"
fi

echo "Ingress IP: $INGRESS_IP"

# Deploy a simple traffic generator pod
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: traffic-gen-script
  namespace: marketly
data:
  run.sh: |
    #!/bin/bash
    set -e
    while true; do
      # /search (will trigger search-api panic when q is empty)
      curl -sf "http://ingress-nginx-controller.marketly.svc.cluster.local/search" || true
      curl -sf "http://ingress-nginx-controller.marketly.svc.cluster.local/search?q=laptop" || true
      # /products
      curl -sf "http://ingress-nginx-controller.marketly.svc.cluster.local/products" || true
      # /auth/login (will trigger user-api — eventually OOMs)
      curl -sf -X POST "http://ingress-nginx-controller.marketly.svc.cluster.local/auth/login" -H "Content-Type: application/json" -d '{"email":"test@example.com","password":"test"}' || true
      # /shipping/quote (will trigger shipping-api NPE)
      curl -sf -X POST "http://ingress-nginx-controller.marketly.svc.cluster.local/shipping/quote" -H "Content-Type: application/json" -d '{"address":"123 Main St","items":[{"sku":"WIDGET-001","quantity":1}]}' || true
      # /checkout (will trigger checkout-api timeout + payments-api rate limit)
      curl -sf -X POST "http://ingress-nginx-controller.marketly.svc.cluster.local/checkout" -H "Content-Type: application/json" -d '{"customer_email":"test@example.com","items":[{"sku":"WIDGET-001","quantity":1}],"shipping_address":"123 Main St"}' || true
      sleep 0.5
    done
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
              cpu: 200m
              memory: 64Mi
      volumes:
        - name: script
          configMap:
            name: traffic-gen-script
            defaultMode: 0755
EOF

echo "  ✓ traffic generator deployed"
echo ""
echo "Traffic is now hitting all endpoints. Pods should start crashing soon."
echo ""
echo "Watch for incidents:"
echo "  kubectl port-forward svc/sentinel -n sentinel 8000:8000"
echo "  curl -s http://localhost:8000/incidents | python3 -m json.tool"
echo ""
echo "Or watch pods:"
echo "  kubectl get pods -n marketly -w"
