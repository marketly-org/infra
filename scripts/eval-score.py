#!/usr/bin/env python3
"""Score Sentinel's marketly eval PRs against ground-truth fix patterns.

Reads eval-artifacts/incidents.json (incident status/confidence per service)
and queries the GitHub API for the most recent Sentinel PR on each of the 9
service repos, then checks whether the PR diff contains the expected fix
pattern (same table as scripts/04-verify-prs.sh, which stays the
human-readable reference).

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
    "shipping-api": "isPresent|orElseThrow|if.*isPresent",
    "analytics-worker": "lock.*order|OrderLock.*InventoryLock|reorder",
    "notification-worker": "max_retries.*5|max_retries=5",
    "recommendation-engine": "shared_mutex|shared_lock|std::mutex",
}

TOKEN = os.environ.get("GITHUB_TOKEN", "")


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
    """Map service name -> incident (most informative one wins)."""
    out = {}
    try:
        with open(os.path.join(art_dir, "incidents.json")) as f:
            for inc in json.load(f):
                svc = (inc.get("cluster") or {}).get("service", "?")
                if svc not in out:
                    out[svc] = inc
    except Exception:
        pass
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

        pr_num, pr_title, pr_url, pr_state = "-", "", "", "-"
        fix_match, note = "no PR", ""

        try:
            prs = json.loads(api(
                f"https://api.github.com/repos/{ORG}/{repo}/pulls"
                "?state=all&per_page=10&sort=created&direction=desc"))
            pr = next(
                (p for p in prs
                 if "sentinel" in (p.get("title") or "").lower()), None)
            if pr:
                pr_num = pr["number"]
                pr_title = pr["title"]
                pr_url = pr["html_url"]
                pr_state = pr.get("state", "-")
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
        "| Service | Incident | Status | Conf | PR | PR state | Fix matches ground truth |",
        "|---|---|---|---|---|---|---|",
    ]
    for r in rows:
        conf = f"{r['confidence']:.0%}" if isinstance(r["confidence"], (int, float)) else "-"
        pr = f"[#{r['pr']}]({r['pr_url']})" if r["pr_url"] else r["pr"]
        lines.append(
            f"| {r['repo']} | {r['incident']} | {r['status']} | {conf} "
            f"| {pr} | {r['pr_state']} | {r['fix_matches']} |")
    lines += [
        "",
        f"**Fixes matching ground truth: {matched} / {len(REPOS)}**",
        "",
        "Raw data: `eval-results` artifact (incidents.json, sentinel logs, "
        "pod snapshots, pr-verification.txt).",
    ]
    with open(os.path.join(art_dir, "score.md"), "w") as f:
        f.write("\n".join(lines) + "\n")

    print(f"scored: {matched}/{len(REPOS)} fixes match ground truth")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "eval-artifacts")
