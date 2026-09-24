# Ground Truth — Marketly Bug Reference

This file documents the exact bug + expected fix for each service. The
`04-verify-prs.sh` script checks Sentinel's PRs against these.

**Detectability (post run #7, 2026-09-23)** — Sentinel v1.7.x detects
incidents from pod logs (error-pattern streaming) and pod status
(CrashLoopBackOff / OOMKilled / restarts). Bugs whose only symptom is
neither of those are *undetectable by design* until synthetic probing /
golden-signal checks land (planned v1.8):

- **Detectable**: search-api, notification-worker, analytics-worker,
  shipping-api, user-api, recommendation-engine.
- **Undetectable (no log line, no crash)**: inventory-api (silent
  oversell), payments-api (no logging code), checkout-api (freezes
  without logging when a downstream hangs).

## checkout-api (Python/FastAPI)

- **Bug**: `app/clients.py` — `httpx.Client()` created without `timeout=` parameter. When downstream services are slow, connections pile up → pool exhaustion → OOM.
- **Symptom**: `MemoryError: Unable to allocate 16.0 MiB` + `connection pool exhausted`
  — **known gap (run #7): the sync httpx client is called directly
  inside an `async def` handler, so a hanging downstream blocks the
  event loop — the service freezes without logging or crashing long
  before any memory grows.** Undetectable by v1.7.x.
- **Fix**: Add explicit timeout to the httpx.Client constructor:
  ```python
  self._client = httpx.Client(timeout=httpx.Timeout(connect=2.0, read=5.0))
  ```

## payments-api (Go)

- **Bug**: `internal/handler/charge.go` — `stripe.CreateCharge()` called with `IdempotencyKey: ""`. Retries create duplicate charges → Stripe rate-limits (429) → cascade.
- **Symptom**: `stripe error: rate_limited — too many requests`
  — **known gap (run #7): the service logs nothing at all** (errors go
  to the HTTP response only), so this signature never appears in pod
  logs. Undetectable by v1.7.x; needs synthetic probing (v1.8).
- **Fix**: Generate + pass an idempotency key:
  ```go
  IdempotencyKey: uuid.New().String(),
  ```

## inventory-api (Go)

- **Bug**: `internal/store/store.go` — `Reserve()` does SELECT then UPDATE in separate statements. Under concurrency, two goroutines both read stock=1, both pass the check, both reserve → oversell → negative availability.
- **Symptom** (corrected after run #7 — the panic quoted here does not
  exist in the code; the real effect is silent data corruption):
  `reserved > stock` in the products table / negative availability in
  `GET /products`. **No log line, no crash — undetectable by v1.7.x.**
  The harness verifies the bug fired by querying the DB directly.
- **Fix**: Single atomic UPDATE:
  ```sql
  UPDATE products SET reserved = reserved + $1 WHERE sku = $2 AND stock - reserved >= $1
  ```

## user-api (TypeScript/Node)

- **Bug**: `src/tokenStore.ts` — refresh tokens stored in `Map` with no eviction. Grows unbounded → OOMKilled.
- **Symptom**: `FATAL ERROR: Ineffective mark-compacts near heap limit`
- **Fix**: Add TTL cleanup or LRU eviction (or move to Redis).

## search-api (Rust/Axum)

- **Bug**: `src/handlers.rs` — `params.q.unwrap()` panics when `q` parameter is missing/empty.
- **Symptom**: `thread 'tokio-runtime-worker' panicked at src/handlers.rs:18:32: called Option::unwrap() on a None value`
- **Fix**: Replace unwrap with proper error handling:
  ```rust
  let q = params.q.ok_or_else(|| AppError::BadRequest("missing q parameter".into()))?;
  ```

## shipping-api (Java/Spring Boot)

- **Bug**: `ShippingService.java` — `carrierResponse.get()` called on `Optional` without `isPresent()` check. NPE when carrier returns empty.
- **Symptom**: `java.util.NoSuchElementException: No value present`
- **Fix**: Use `orElseThrow` or `isPresent` check:
  ```java
  QuoteResponse quote = carrierResponse.orElseThrow(() ->
      new BadRequestException("carrier returned no quote"));
  ```

## analytics-worker (Ruby/Sidekiq)

- **Bug**: `app/workers/payment_worker.rb` — acquires `InventoryLock` then `OrderLock`. `OrderWorker` acquires them in opposite order. Deadlock under concurrency.
- **Symptom**: `ERROR -- : Job failed: deadlock detected`
  — **known gap (run #10): the deadlock is unreachable.** The service's
  own `app/lock/distributed_lock.rb` calls the old redis-gem API
  (`.set(key, token, nx: true, px: ...)`) against a redis-client object,
  so every job dies first with `NoMethodError: undefined method 'set'
  for an instance of RedisClient`. That is a genuine (unplanted) bug in
  the repo; Sentinel may legitimately investigate and fix IT instead.
- **Fix**: Make `PaymentWorker` acquire `OrderLock` before `InventoryLock` (same order as `OrderWorker`).

## notification-worker (Python/Celery)

- **Bug**: `app/tasks.py` — `@app.task(max_retries=0)` (typo, should be 5). Failed emails are never retried — each one is a permanent, silent loss.
- **Symptom** (corrected after run #7 — with max_retries=0 there is no
  retry loop; the task marks itself succeeded with `status: failed`):
  `[... ERROR/ForkPoolWorker-N] send_email.failed id=... err=gaierror: [Errno -2] Name or service not known`
- **Fix**: Change `max_retries=0` to `max_retries=5`:
  ```python
  @app.task(max_retries=5, retry_backoff=True)
  ```

## recommendation-engine (C++/gRPC)

- **Bug**: `src/cache.cpp` + `src/engine.cpp` — `std::vector<RecommendationItem>` iterated while another thread appends. Iterator invalidation → segfault.
- **Symptom**: `Segmentation fault (core dumped)` at `std::vector::begin()`
- **Fix**: Add `std::shared_mutex` — shared lock during iteration, exclusive lock during append:
  ```cpp
  std::shared_mutex mutex_;
  // In iterate: std::shared_lock lock(mutex_);
  // In append:  std::unique_lock lock(mutex_);
  ```
