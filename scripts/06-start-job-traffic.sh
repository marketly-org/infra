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
# The planted bug (src/cache.cpp): the recommendation pool vector is
# iterated by GetRecommendations while AppendItem appends to it — iterator
# invalidation, segfault. Nothing in the HTTP traffic paths ever calls this
# gRPC service, so without this injector the bug is unreachable. We ship
# the proto via ConfigMap (the server has no reflection) and run concurrent
# recommend+append loops with grpcurl.
# ---------------------------------------------------------------------------
echo "=== Deploying gRPC injector (recommendation-engine) ==="

cat <<'PROTOEOF' | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: recommendation-proto
  namespace: marketly
data:
  recommendation.proto: |
    syntax = "proto3";

    package marketly.recommendation.v1;

    message RecommendationItem {
      string sku = 1;
      string name = 2;
      string category = 3;
      double score = 4;
      int32 price_cents = 5;
    }

    message RecommendRequest {
      string user_id = 1;
      string category = 2;
      int32 limit = 3;
    }

    message RecommendResponse {
      string user_id = 1;
      repeated RecommendationItem items = 2;
      string trace_id = 3;
    }

    message AppendItemRequest {
      RecommendationItem item = 1;
    }

    message AppendItemResponse {
      bool accepted = 1;
      int32 pool_size = 2;
    }

    service RecommendationService {
      rpc GetRecommendations(RecommendRequest) returns (RecommendResponse);
      rpc AppendItem(AppendItemRequest) returns (AppendItemResponse);
      rpc Health(HealthRequest) returns (HealthResponse);
    }

    message HealthRequest {}

    message HealthResponse {
      string status = 1;
      string service = 2;
      string version = 3;
      int32 pool_size = 4;
    }
PROTOEOF

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
          image: fullstorydev/grpcurl:latest-alpine
          command: ["/bin/sh", "-c"]
          args:
            - |
              GRPC="grpcurl -plaintext -max-time 5 -import-path /protos -proto recommendation.proto"
              TARGET="recommendation-engine.${NS}.svc.cluster.local:50051"
              SVC="marketly.recommendation.v1.RecommendationService"
              # Run #7 post-mortem: the injector swallowed all output
              # (>/dev/null 2>&1 || true) so there was no way to tell
              # whether the calls were even reaching the engine. Log a
              # Health check up front and keep per-loop counters.
              echo "grpc-injector: probing Health on \$TARGET ..."
              if \$GRPC -d '{}' "\$TARGET" "\$SVC/Health" 2>&1; then
                echo "grpc-injector: Health OK"
              else
                echo "grpc-injector: Health FAILED (proto/service/port mismatch?)"
              fi
              ok=0 fail=0
              recommender() {
                while true; do
                  if \$GRPC -d '{"user_id":"load-'"\$1"'","limit":20}' \\
                    "\$TARGET" "\$SVC/GetRecommendations" >/dev/null 2>&1; then
                    ok=\$((ok + 1))
                  else
                    fail=\$((fail + 1))
                  fi
                  # Progress line every 100 calls so the artifacts show
                  # whether traffic is flowing (and at what error rate).
                  total=\$((ok + fail))
                  if [ \$((total % 100)) -eq 0 ]; then
                    echo "grpc-injector: \$total calls (ok=\\$ok fail=\\$fail)"
                  fi
                done
              }
              appender() {
                i=0
                while true; do
                  i=\$((i + 1))
                  \$GRPC -d '{"item":{"sku":"INJ-'\$i'","name":"Injected item","category":"toys","score":0.9,"price_cents":999}}' \\
                    "\$TARGET" "\$SVC/AppendItem" >/dev/null 2>&1 || true
                  sleep 0.1
                done
              }
              recommender a &
              recommender b &
              recommender c &
              recommender d &
              recommender e &
              recommender f &
              appender &
              appender
          volumeMounts:
            - name: protos
              mountPath: /protos
          resources:
            requests:
              cpu: 50m
              memory: 16Mi
            limits:
              cpu: 300m
              memory: 64Mi
      volumes:
        - name: protos
          configMap:
            name: recommendation-proto
EOF

echo "  ✓ grpc injector deployed (4x GetRecommendations + 1x AppendItem loop)"

echo ""
echo "Worker queues and gRPC endpoints are now receiving traffic. Expected failure signatures:"
echo "  notification-worker: SMTP ConnectionRefusedError, tasks fail permanently (max_retries=0)"
echo "  analytics-worker:    lock-acquire timeouts / stuck jobs (deadlock), .rb errors"
echo "  recommendation-engine: Segmentation fault (core dumped) — iterator invalidation"
