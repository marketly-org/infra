#!/usr/bin/env python3
"""Multi-provider LLM bench for Sentinel's workload (Gemini / Cerebras).

Runs from a GitHub Actions runner (US egress) because the sandbox IP is
geo-blocked by Google (HK unsupported) and Cloudflare-challenged by Cerebras.

Per provider:
  0. list models          -> validates the key, discovers what exists
  1. quality tests A+B    -> the same two real run-#12 incident prompts used
                             in or-bench.py (investigate user-api crash-loop,
                             fix notification-worker gaierror/max_retries)
  2. burst test           -> 12 rapid tiny calls on the fast-tier candidate;
                             counts 429s and captures the RAW error body so we
                             can verify v1.7.4's rate-limit detection phrasing

Output: bench-results/results.jsonl (one line per call) + summary table.
"""
import json, os, sys, time, urllib.request, urllib.error

MAX_TOKENS = int(os.environ.get("MAX_TOKENS", "8000"))
OUT_DIR = "bench-results"
os.makedirs(OUT_DIR, exist_ok=True)
OUT = os.path.join(OUT_DIR, "results.jsonl")

PROVIDERS = {}

if os.environ.get("GEMINI_API_KEY"):
    PROVIDERS["gemini"] = {
        "base": "https://generativelanguage.googleapis.com/v1beta/openai",
        "key": os.environ["GEMINI_API_KEY"],
        # compat endpoint: same models, same quotas as the native API goai uses.
        # round 2: 3.5 series (2.5-flash-lite is deprecated for new keys;
        # 2.5-flash already scored 5/5 + 5/5 in round 1).
        "models": [m for m in os.environ.get(
            "GEMINI_MODELS", "gemini-3.5-flash,gemini-3.5-flash-lite"
            ",gemini-3.8-flash").split(",") if m],
        "burst_model": "gemini-3.5-flash-lite",
    }
if os.environ.get("CEREBRAS_API_KEY"):
    PROVIDERS["cerebras"] = {
        "base": "https://api.cerebras.ai/v1",
        "key": os.environ["CEREBRAS_API_KEY"],
        "models": [],          # filled from /models listing
        "want": ["gpt-oss-120b", "llama-3.3-70b", "qwen-3-27b", "qwen-3.8-27b",
                 "zai-glm-4.6"],
        "burst_model": None,   # picked after listing
    }

# ---------------------------------------------------------------- test prompts
TEST_A = {
    "name": "investigate-userapi",
    "system": ("You are an SRE incident investigator. Respond with ONLY a JSON "
               "object (no markdown, no prose): "
               '{"root_cause": "<one paragraph>", "confidence": <0-1>, '
               '"files_to_read": ["<path>", ...]}'),
    "user": """SERVICE: user-api (Node.js 20 / TypeScript, Express + node-postgres)
SYMPTOM: container crash-looping all run, restart_count=12, exit code 1

POD LOGS (final lines before each crash):
/app/node_modules/pg-pool/index.js:45 Error.captureStackTrace(err)
Error: Connection terminated due to connection timeout
    at async getUserByEmail (/app/dist/db.js:35:20)
  [cause]: Error: Connection terminated unexpectedly
Node.js v20.20.2

RUNTIME CONTEXT (from the LIVE pod spec — ground truth, do not contradict it):
- env vars SET (names): NODE_OPTIONS=--max-old-space-size=64, USER_DATABASE_URL=(secret), PORT=8080, JWT_SECRET=(secret)
- env vars NOT set: DATABASE_URL
- container resources: memory limit 256Mi, cpu 250m

REPO (excerpt):
src/db.ts:
  export const pool = new Pool({ connectionString: process.env.USER_DATABASE_URL, connectionTimeoutMillis: 2000 });
src/server.ts:
  app.get('/user', async (req, res) => { const u = await getUserByEmail(req.query.email); res.json(u); });
src/tokenStore.ts:
  const tokens = new Map();  // grows on every login; entries are never deleted

LOAD: sustained ~160 logins/second (load test).

QUESTION: What is the root cause of the crash loop? Return the JSON object only.""",
}

TEST_B = {
    "name": "fix-notification-worker",
    "system": ("You are an autonomous fix engine. Fix the bug described below. "
               "Output ONLY diff blocks in this exact format, one per file:\n"
               "<<<<<<< SEARCH\n<exact existing code lines>\n=======\n<replacement lines>\n"
               ">>>>>>> REPLACE"),
    "user": """SERVICE: notification-worker (Python 3.12, Celery)
INCIDENT LOGS (repeating every few seconds):
[2026-09-24 11:55:01] ERROR/ForkPoolWorker-4] send_email.failed err=gaierror: [Errno -2] Name or service not known

REPO (excerpt):
app/tasks.py:
  @celery.task(bind=True, max_retries=0)
  def send_email(self, payload):
      try:
          client = EmailClient()
          client.send(payload)
      except (SMTPConnectError, SMTPServerDisconnected) as exc:
          raise self.retry(exc=exc, countdown=5)

app/email_client.py:
  class EmailClient:
      def __init__(self):
          self.host = os.getenv("SMTP_HOST", "mailhog.marketly.svc.cluster.local")
          self.port = int(os.getenv("SMTP_PORT", "2525"))

RUNTIME CONTEXT (live pod — ground truth): SMTP_HOST IS set (secret ref, DNS
name of the in-cluster mail relay). The failure is transient DNS resolution
(gaierror) under load. Because gaierror is not in the except tuple AND
max_retries=0, every task fails permanently on the first attempt.

TASK: patch the code so transient DNS/connect failures are retried with backoff
instead of permanently failing. Return only the SEARCH/REPLACE block(s).""",
}

# ---------------------------------------------------------------- http helpers
def post_chat(base, key, model, messages, max_tokens, timeout=180):
    """One chat call. Returns (ok, data_or_error, secs)."""
    body = {"model": model, "messages": messages,
            "max_tokens": max_tokens, "temperature": 0.2}
    req = urllib.request.Request(
        base.rstrip("/") + "/chat/completions",
        data=json.dumps(body).encode(),
        headers={"Authorization": f"Bearer {key}",
                 "Content-Type": "application/json",
                 # Cerebras sits behind Cloudflare: the default python-urllib
                 # UA gets error-1010'd. Browser UA for identification only.
                 "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) "
                               "AppleWebKit/537.36 (KHTML, like Gecko) "
                               "Chrome/131.0.0.0 Safari/537.36"})
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return True, json.loads(r.read().decode()), time.time() - t0
    except urllib.error.HTTPError as e:
        raw = e.read().decode(errors="replace")
        try: raw = json.loads(raw).get("error", {}).get("message", raw)[:400]
        except Exception: raw = raw[:400]
        return False, f"HTTP {e.code}: {raw}", time.time() - t0
    except Exception as e:
        return False, f"{type(e).__name__}: {e}", time.time() - t0

def list_models(base, key):
    req = urllib.request.Request(
        base.rstrip("/") + "/models",
        headers={"Authorization": f"Bearer {key}",
                 "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) "
                               "AppleWebKit/537.36 (KHTML, like Gecko) "
                               "Chrome/131.0.0.0 Safari/537.36"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return [m.get("id", "") for m in json.loads(r.read().decode()).get("data", [])], None
    except urllib.error.HTTPError as e:
        raw = e.read().decode(errors="replace")[:300]
        return None, f"HTTP {e.code}: {raw}"
    except Exception as e:
        return None, f"{type(e).__name__}: {e}"

def record(row):
    with open(OUT, "a") as f:
        f.write(json.dumps(row) + "\n")

# ---------------------------------------------------------------- scoring
def score_A(content):
    if not content: return 0, ["empty"]
    pts, notes = 0, []
    c = content.strip().strip("`")
    try:
        j = json.loads(c[c.find("{"):c.rfind("}") + 1])
        pts += 2; notes.append("valid-json")
        rc = j.get("root_cause", "").lower()
        if any(k in rc for k in ["heap", "memory", "tokenstore", "token store", "map"]): pts += 2; notes.append("root-cause-hit")
        if any(k in rc for k in ["gc", "garbage", "event loop", "old-space"]): pts += 1; notes.append("mechanism")
        if "database_url" in rc and "user_database_url" not in rc and "not set" not in rc and "is set" not in rc: notes.append("ENV-HALLUCINATION")
    except Exception:
        notes.append("not-json")
    return pts, notes

def score_B(content):
    if not content: return 0, ["empty"]
    pts, notes = 0, []
    if "<<<<<<< SEARCH" in content and ">>>>>>> REPLACE" in content: pts += 2; notes.append("diff-format")
    else: notes.append("NO-DIFF-FORMAT")
    if "gaierror" in content: pts += 2; notes.append("gaierror-caught")
    if "max_retries=0" in content and "max_retries=0" in content.split(">>>>>>> REPLACE")[-1]: pass
    import re
    m = re.search(r"max_retries=(\d)", content)
    if m and int(m.group(1)) > 0: pts += 1; notes.append(f"retries={m.group(1)}")
    elif not m: notes.append("max_retries-untouched")
    if content.count("<<<<<<< SEARCH") == 1: pts += 1; notes.append("single-block")
    else: notes.append(f"multi-block({content.count('<<<<<<< SEARCH')})")
    return pts, notes

# ---------------------------------------------------------------- main
def bench_quality(prov, base, key, model):
    for test in (TEST_A, TEST_B):
        msgs = [{"role": "system", "content": test["system"]},
                {"role": "user", "content": test["user"]}]
        ok, data, secs = post_chat(base, key, model, msgs, MAX_TOKENS)
        if not ok:
            print(f"  [{model}] {test['name']}: FAIL {data}")
            record({"provider": prov, "model": model, "test": test["name"],
                    "ok": False, "error": data, "secs": round(secs, 1)})
            continue
        ch = (data.get("choices") or [{}])[0]
        content = ch.get("message", {}).get("content") or ""
        usage = data.get("usage", {})
        finish = ch.get("finish_reason")
        scorer = score_A if test is TEST_A else score_B
        pts, notes = scorer(content)
        print(f"  [{model}] {test['name']}: {secs:5.1f}s score={pts}/5 "
              f"[{', '.join(notes)}] reasoning_tok="
              f"{(usage.get('completion_tokens_details') or {}).get('reasoning_tokens', '?')}")
        record({"provider": prov, "model": model, "test": test["name"], "ok": True,
                "secs": round(secs, 1), "score": pts, "notes": notes,
                "finish": finish, "usage": usage, "content": content})

def bench_burst(prov, base, key, model, n=12):
    ok_n, err_429, other = 0, 0, 0
    raw_429 = None
    t0 = time.time()
    for i in range(n):
        ok, data, _ = post_chat(
            base, key, model,
            [{"role": "user", "content": "Reply with the single word OK"}], 8,
            timeout=60)
        if ok: ok_n += 1
        elif isinstance(data, str) and data.startswith("HTTP 429"):
            err_429 += 1
            if raw_429 is None: raw_429 = data
        else: other += 1
    dt = time.time() - t0
    print(f"  [burst {model}] {ok_n}/{n} ok, {err_429} x429, {other} other, {dt:.1f}s")
    if raw_429: print(f"    raw 429 body: {raw_429[:220]}")
    record({"provider": prov, "model": model, "test": "burst",
            "ok": ok_n, "err_429": err_429, "other": other,
            "secs": round(dt, 1), "raw_429": raw_429})

def main():
    wanted = os.environ.get("PROVIDERS", "gemini,cerebras").split(",")
    for prov in wanted:
        p = PROVIDERS.get(prov)
        if not p:
            print(f"== {prov}: no key set, skipping"); continue
        print(f"\n===== {prov.upper()} =====")
        models, err = list_models(p["base"], p["key"])
        if err:
            print(f"  LIST MODELS FAILED: {err}")
            record({"provider": prov, "test": "list-models", "ok": False, "error": err})
            continue
        print(f"  models: {' '.join(models)}")
        record({"provider": prov, "test": "list-models", "ok": True, "models": models})

        todo = p["models"]
        if not todo and p.get("want"):
            for w in p["want"]:
                hit = [m for m in models if w in m]
                if hit: todo.append(hit[0])
            todo = todo[:2]
        if not todo:
            print("  no candidate models found"); continue

        for m in todo:
            print(f" -- quality: {m}")
            bench_quality(prov, p["base"], p["key"], m)

        burst_m = p.get("burst_model") or (todo[-1] if todo else None)
        if burst_m:
            print(f" -- burst: {burst_m}")
            bench_burst(prov, p["base"], p["key"], burst_m)

    print(f"\nresults -> {OUT}")

if __name__ == "__main__":
    main()
