#!/bin/bash
# 06-start-job-traffic.sh — feeds the two background workers.
#
# Post-mortem of eval run #4: no service in the org ever enqueues jobs,
# so notification-worker (Celery) and analytics-worker (Sidekiq) sat idle
# and their planted bugs were unreachable. This script deploys two small
# injectors:
#
#   sidekiq-injector — LPUSHes OrderWorker/PaymentWorker jobs onto the
#                      orders/payments queues. Concurrent order+payment
#                      jobs are what trigger the reversed lock-order
#                      deadlock in PaymentWorker.
#   celery-injector  — uses the notification-worker's own image to call
#                      `celery call app.tasks.send_email`, so the payload
#                      format is exactly what the worker expects. SMTP
#                      does not exist, so every send fails — which is the
#                      signal that exercises the max_retries=0 bug.
set -euo pipefail

NS=marketly
REDIS_HOST=redis.${NS}.svc.cluster.local
REDIS_PASS="${REDIS_PASS:-marketly-eval}"

echo "=== Deploying Sidekiq job injector (orders + payments queues) ==="

cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sidekiq-injector
  namespace: ${NS}
  labels:
    app: sidekiq-injector
spec:
  replicas: 1
  selector:
    matchLabels:
      app: sidekiq-injector
  template:
    metadata:
      labels:
        app: sidekiq-injector
    spec:
      containers:
        - name: injector
          image: redis:7-alpine
          command: ["/bin/sh", "-c"]
          args:
            - |
              i=0
              while true; do
                i=\$((i + 1))
                JID=\$( (echo \$i; date +%s%N) | md5sum | cut -c1-24)
                # NOTE: integer epoch only — busybox date has no %N/%3N
                # fractional support, and run #7's "date +%s.%3N" produced
                # TS="1790192939." → invalid JSON → every job died at
                # parse ("Invalid JSON for job") and the deadlock bug was
                # never exercised.
                TS=\$(date +%s)
                # OrderWorker: OrderLock -> InventoryLock (correct order)
                redis-cli -h ${REDIS_HOST} -a ${REDIS_PASS} --no-auth-warning LPUSH queue:orders \\
                  "{\"class\":\"Analytics::Workers::OrderWorker\",\"args\":[{\"id\":\"ord-inj-\$i\",\"user_id\":1,\"total_cents\":1999,\"items\":[{\"sku\":\"WIDGET-001\",\"quantity\":1}],\"placed_at\":\"2026-01-01T00:00:00Z\"}],\"queue\":\"orders\",\"jid\":\"\$JID\",\"created_at\":\$TS,\"enqueued_at\":\$TS,\"retry\":true}" >/dev/null
                JID2=\$( (echo \$i; date +%s%N) | md5sum | cut -c1-24)
                # PaymentWorker: InventoryLock -> OrderLock (reversed = the bug)
                redis-cli -h ${REDIS_HOST} -a ${REDIS_PASS} --no-auth-warning LPUSH queue:payments \\
                  "{\"class\":\"Analytics::Workers::PaymentWorker\",\"args\":[{\"payment_id\":\"pay-inj-\$i\",\"order_id\":\"ord-inj-\$i\",\"user_id\":1,\"amount_cents\":1999,\"kind\":\"charge\"}],\"queue\":\"payments\",\"jid\":\"\$JID2\",\"created_at\":\$TS,\"enqueued_at\":\$TS,\"retry\":true}" >/dev/null
                sleep 0.3
              done
          resources:
            requests:
              cpu: 50m
              memory: 16Mi
            limits:
              cpu: 200m
              memory: 64Mi
EOF

echo "  ✓ sidekiq injector deployed"

echo "=== Deploying Celery job injector (notifications queue) ==="

# Use the exact image the running notification-worker deployment uses, so
# `celery call` serializes the payload with the app's own config.
NOTIF_IMAGE=$(kubectl -n ${NS} get deploy notification-worker \
  -o jsonpath='{.spec.template.spec.containers[0].image}')

cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: celery-injector
  namespace: ${NS}
  labels:
    app: celery-injector
spec:
  replicas: 1
  selector:
    matchLabels:
      app: celery-injector
  template:
    metadata:
      labels:
        app: celery-injector
    spec:
      containers:
        - name: injector
          image: ${NOTIF_IMAGE}
          command: ["/bin/sh", "-c"]
          args:
            - |
              i=0
              while true; do
                i=\$((i + 1))
                celery -A app.celery_app call app.tasks.send_email \\
                  --args '[{"id":"notif-inj-'\$i'","to_address":"customer@example.com","subject":"Your order","body":"Thanks for your purchase!"}]' >/dev/null 2>&1 || true
                sleep 2
              done
          env:
            - name: REDIS_URL
              value: "redis://:${REDIS_PASS}@${REDIS_HOST}:6379/0"
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 300m
              memory: 192Mi
EOF

echo "  ✓ celery injector deployed (image: ${NOTIF_IMAGE})"

# ---------------------------------------------------------------------------
# gRPC injector — recommendation-engine.
#
# The planted bug (src/cache.cpp + engine.cpp): the recommendation pool
# vector is iterated by GetRecommendations while AppendItem appends to
# it — iterator invalidation, segfault. Nothing in the HTTP traffic
# paths ever calls this gRPC service, so without an injector the bug is
# unreachable.
#
# Run #10 post-mortem: the grpcurl-based injector fired ~4600 calls per
# loop with zero failures but never crashed the engine — every call
# spawns a NEW grpcurl process, so the server-side iteration duty cycle
# was only a few percent and the ~17 vector reallocations all landed in
# the gaps. This injector uses ONE persistent channel with 8 recommender
# threads + 2 unsleeping appender threads, saturating the engine so any
# capacity-doubling realloc overlaps an in-flight iteration.
# ---------------------------------------------------------------------------
echo "=== Deploying gRPC injector (recommendation-engine) ==="

cat <<'INJPY' | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: grpc-injector-script
  namespace: marketly
data:
  injector.py: |
    """Persistent-connection gRPC load injector.

    Saturates recommendation-engine with concurrent GetRecommendations
    (iterate) + AppendItem (mutate) traffic so the unsynchronized vector
    race in cache.cpp/engine.cpp actually fires.
    """
    import threading
    import time
    import sys
    import os

    os.makedirs("/protos_gen", exist_ok=True)
    sys.path.insert(0, "/protos_gen")

    from grpc_tools import protoc
    rc = protoc.main(
        ["-I/protos", "--python_out=/protos_gen",
         "--grpc_python_out=/protos_gen", "/protos/recommendation.proto"]
    )
    if rc != 0:
        print("grpc-injector: protoc failed", flush=True)
        sys.exit(1)

    import grpc
    import recommendation_pb2 as pb2
    import recommendation_pb2_grpc as pb2_grpc

    TARGET = "recommendation-engine.marketly.svc.cluster.local:50051"
    channel = grpc.insecure_channel(TARGET)
    stub = pb2_grpc.RecommendationServiceStub(channel)

    ok = 0
    fail = 0
    lock = threading.Lock()

    def log(msg):
        print(f"grpc-injector: {msg}", flush=True)

    try:
        h = stub.Health(pb2.HealthRequest(), timeout=10)
        log(f"Health OK status={h.status} pool_size={h.pool_size}")
    except Exception as e:
        log(f"Health FAILED (proto/service/port mismatch?): {e}")

    def recommender(n):
        global ok, fail
        req = pb2.RecommendRequest(user_id=f"load-{n}", limit=20)
        while True:
            try:
                stub.GetRecommendations(req, timeout=30)
                with lock:
                    ok += 1
            except Exception:
                with lock:
                    fail += 1

    def appender(n):
        i = 0
        while True:
            i += 1
            item = pb2.RecommendationItem(
                sku=f"INJ-{n}-{i}", name="Injected item",
                category="toys", score=0.9, price_cents=999,
            )
            try:
                stub.AppendItem(pb2.AppendItemRequest(item=item), timeout=30)
            except Exception:
                pass

    for i in range(8):
        threading.Thread(target=recommender, args=(i,), daemon=True).start()
    for i in range(2):
        threading.Thread(target=appender, args=(i,), daemon=True).start()

    while True:
        time.sleep(10)
        with lock:
            log(f"calls ok={ok} fail={fail}")
INJPY

cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: grpc-injector
  namespace: marketly
  labels:
    app: grpc-injector
spec:
  replicas: 1
  selector:
    matchLabels:
      app: grpc-injector
  template:
    metadata:
      labels:
        app: grpc-injector
    spec:
      containers:
        - name: injector
          image: python:3.12-slim
          command: ["/bin/sh", "-c"]
          args:
            - |
              pip install --no-cache-dir -q grpcio grpcio-tools \\
                && echo "grpc-injector: deps installed" \\
                && python /scripts/injector.py
          volumeMounts:
            - name: protos
              mountPath: /protos
            - name: script
              mountPath: /scripts
          resources:
            requests:
              cpu: 100m
              memory: 64Mi
            limits:
              cpu: 1000m
              memory: 256Mi
      volumes:
        - name: protos
          configMap:
            name: recommendation-proto
        - name: script
          configMap:
            name: grpc-injector-script
            defaultMode: 0755
EOF

echo "  ✓ grpc injector deployed (persistent channel, 8x recommend + 2x append threads)"

echo ""
echo "Worker queues and gRPC endpoints are now receiving traffic. Expected failure signatures:"
echo "  notification-worker: SMTP ConnectionRefusedError, tasks fail permanently (max_retries=0)"
echo "  analytics-worker:    lock-acquire timeouts / stuck jobs (deadlock), .rb errors"
echo "  recommendation-engine: Segmentation fault (core dumped) — iterator invalidation"
