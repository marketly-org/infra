#!/usr/bin/env python3
"""Score Sentinel's marketly eval PRs against ground-truth fix patterns.

Reads eval-artifacts/incidents.json (incident status/confidence per service)
and queries the GitHub API for Sentinel PRs opened DURING this eval run on
each of the 9 service repos, then checks whether the PR diff contains the
expected fix pattern (same table as scripts/04-verify-prs.sh, which stays
the human-readable reference).

Only PRs created after $EVAL_RUN_START (set by 10-github-eval.sh at run
start) are counted — a stale PR from an earlier run must never inflate
the score (this happened in the 2026-09-23 run: year-old PRs scored 5/9
on a zero-incident run).

Writes:
  <art_dir>/score.json  — structured results
  <art_dir>/score.md    — markdown table for the job summary

Never exits non-zero: a bad score is eval data, not an error.
"""
import json
import os
import re
import sys
import urllib.request

ORG = "marketly-org"
REPOS = [
    "checkout-api", "payments-api", "inventory-api", "user-api",
    "search-api", "shipping-api", "analytics-worker", "notification-worker",
    "recommendation-engine",
]
EXPECTED = {
    "checkout-api": "timeout",
    "payments-api": "IdempotencyKey",
    "inventory-api": "UPDATE.*reserved",
    "user-api": "LRU|TTL|setTimeout|eviction",
    "search-api": "ok_or|is_none|return Err",
    # `orElse` subsumes orElseThrow/orElseGet — run #15's PR #6 used
    # orElseGet(() -> fallback) (a valid graceful-handling fix) and was
    # missed by the stricter orElseThrow-only pattern, desyncing score.md
    # from pr-verification.txt (04-verify-prs.sh already had `orElse`).
    "shipping-api": "isPresent|orElse",
    # analytics-worker: two acceptable fixes (decision 2026-09-24). The
    # planted deadlock (lock-order fix) is UNREACHABLE behind the repo's
    # genuine NoMethodError — distributed_lock.rb calls the old redis-gem
    # .set API on a redis-client object, so every job dies before the
    # deadlock can engage. A correct fix of THAT bug (c.call("SET", ...)
    # or equivalent redis-client API usage) is a genuine, correct fix of
    # the observed error and scores YES. The deadlock becomes reachable
    # (and scorable) only after that fix merges.
    "analytics-worker": "lock.*order|OrderLock.*InventoryLock|reorder|\\.call\\(\\s*[\"']SET",
    "notification-worker": "max_retries.*5|max_retries=5",
    "recommendation-engine": "shared_mutex|shared_lock|std::mutex",
}

TOKEN = os.environ.get("GITHUB_TOKEN", "")
# ISO-8601 timestamp recorded when the eval driver started. PRs created
# before this are from earlier runs and must be ignored.
RUN_START = os.environ.get("EVAL_RUN_START", "")


def _parse_ts(ts):
    """'2026-09-23T16:41:57Z' -> epoch seconds (0 if unparseable)."""
    import datetime
    try:
        return datetime.datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()
    except Exception:
        return 0.0


def api(url, accept="application/vnd.github+json"):
    req = urllib.request.Request(
        url,
        headers={
            "Authorization": f"token {TOKEN}",
            "Accept": accept,
            "User-Agent": "marketly-eval",
        },
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.read().decode()


def load_incidents(art_dir):
    """Map service name -> incident (most informative one wins).

    incidents.json is newest-first (API sorts by updated_at DESC), so the
    first row per service is the NEWEST. With the fix-service budget
    (chart 1.7.7) a capped or already-attempted service records 'skipped'
    incidents at re-detection time — a later 'skipped' must not shadow an
    earlier real investigation (fix_proposed/failed with a PR behind it).
    Rule: newest non-skipped wins; all-skipped -> newest skipped.
    """
    out = {}
    skipped = {}
    try:
        with open(os.path.join(art_dir, "incidents.json")) as f:
            data = json.load(f)
        # The Sentinel API marshals an empty incident list as JSON null.
        for inc in data or []:
            svc = (inc.get("cluster") or {}).get("service", "?")
            if inc.get("status") == "skipped":
                if svc not in skipped:
                    skipped[svc] = inc
            elif svc not in out:
                out[svc] = inc
    except Exception:
        pass
    for svc, inc in skipped.items():
        out.setdefault(svc, inc)
    return out


def main(art_dir):
    incidents = load_incidents(art_dir)
    rows = []
    matched = 0

    for repo in REPOS:
        inc = incidents.get(repo)
        inc_status = (inc or {}).get("status", "-")
        rc = ((inc or {}).get("state") or {}).get("root_cause") or {}
        conf = rc.get("confidence")

        pr_num, pr_title, pr_url, pr_state, pr_merged = "-", "", "", "-", "-"
        fix_match, note = "no PR", ""

        try:
            prs = json.loads(api(
                f"https://api.github.com/repos/{ORG}/{repo}/pulls"
                "?state=all&per_page=20&sort=created&direction=desc"))
            cutoff = _parse_ts(RUN_START)
            pr = next(
                (p for p in prs
                 if "sentinel" in (p.get("title") or "").lower()
                 and (p.get("head") or {}).get("ref", "").startswith("sentinel/")
                 and (not cutoff or _parse_ts(p.get("created_at") or "") >= cutoff - 60)),
                None)
            if pr:
                pr_num = pr["number"]
                pr_title = pr["title"]
                pr_url = pr["html_url"]
                pr_state = pr.get("state", "-")
                # merged PRs also report state=closed; merged_at distinguishes
                # "auto-merged, deployed, recovered" from "closed unmerged".
                pr_merged = (pr.get("merged_at") or "-") if pr_state == "closed" else "-"
                diff = api(
                    f"https://api.github.com/repos/{ORG}/{repo}/pulls/{pr_num}",
                    accept="application/vnd.github.v3.diff")
                if re.search(EXPECTED[repo], diff):
                    fix_match = "YES"
                    matched += 1
                else:
                    fix_match = "NO"
            else:
                note = "no Sentinel PR"
        except Exception as e:  # noqa: BLE001 — a repo error is data, not a crash
            fix_match = "error"
            note = str(e)[:60]

        rows.append({
            "repo": repo,
            "incident": "yes" if inc else "no",
            "status": inc_status,
            "confidence": conf,
            "pr": pr_num,
            "pr_state": pr_state,
            "pr_merged": pr_merged,
            "pr_url": pr_url,
            "pr_title": pr_title,
            "fix_matches": fix_match,
            "note": note,
        })
    with open(os.path.join(art_dir, "score.json"), "w") as f:
        json.dump({"matched": matched, "total": len(REPOS), "rows": rows}, f, indent=2)

    lines = [
        "## Sentinel eval — results",
        "",
        "| Service | Incident | Status | Conf | PR | PR state | Merged | Fix matches ground truth |",
        "|---|---|---|---|---|---|---|---|",
    ]
    n_merged = sum(1 for r in rows if r.get("pr_merged") not in ("-", None))
    for r in rows:
        conf = f"{r['confidence']:.0%}" if isinstance(r["confidence"], (int, float)) else "-"
        pr = f"[#{r['pr']}]({r['pr_url']})" if r["pr_url"] else r["pr"]
        merged = "✅" if r.get("pr_merged") not in ("-", None) else "-"
        lines.append(
            f"| {r['repo']} | {r['incident']} | {r['status']} | {conf} "
            f"| {pr} | {r['pr_state']} | {merged} | {r['fix_matches']} |")
    lines += [
        "",
        f"**Fixes matching ground truth: {matched} / {len(REPOS)} · auto-merged: {n_merged}**",
        "",
        "Raw data: `eval-results` artifact (incidents.json, sentinel logs, "
        "pod snapshots, pr-verification.txt).",
    ]
    with open(os.path.join(art_dir, "score.md"), "w") as f:
        f.write("\n".join(lines) + "\n")

    print(f"scored: {matched}/{len(REPOS)} fixes match ground truth")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "eval-artifacts")
