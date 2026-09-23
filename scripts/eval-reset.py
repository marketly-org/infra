#!/usr/bin/env python3
"""Reset marketly service repos to their pre-eval state.

For each of the 9 service repos:
  1. Close any open PRs whose title mentions Sentinel (unmerged attempts).
  2. Force-push main back to the SHA recorded before the eval
     (eval-artifacts/<repo>.sha). This reverts Sentinel's auto-merged fixes
     and the "deploy: sha-XXX" manifest commits they triggered, so the
     planted bugs are findable again on the next run.

Never exits non-zero — a failed reset on one repo shouldn't sink the run,
it just gets reported.
"""
import json
import os
import sys
import urllib.error
import urllib.request

ORG = "marketly-org"
REPOS = [
    "checkout-api", "payments-api", "inventory-api", "user-api",
    "search-api", "shipping-api", "analytics-worker", "notification-worker",
    "recommendation-engine",
]

TOKEN = os.environ.get("GITHUB_TOKEN", "")


def api(url, method="GET", body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        url, data=data, method=method,
        headers={
            "Authorization": f"token {TOKEN}",
            "Accept": "application/vnd.github+json",
            "Content-Type": "application/json",
            "User-Agent": "marketly-eval",
        })
    with urllib.request.urlopen(req, timeout=30) as r:
        txt = r.read().decode()
        return json.loads(txt) if txt else {}


def reset_repo(repo, art_dir):
    sha_file = os.path.join(art_dir, f"{repo}.sha")
    if not os.path.exists(sha_file):
        print(f"  {repo}: no recorded SHA — skipping")
        return
    with open(sha_file) as f:
        pre_sha = f.read().strip()

    # 1. Close open Sentinel PRs.
    closed = 0
    try:
        prs = api(f"https://api.github.com/repos/{ORG}/{repo}/pulls?state=open")
        for pr in prs:
            if "sentinel" in (pr.get("title") or "").lower():
                api(pr["url"], method="PATCH", body={"state": "closed"})
                closed += 1
    except urllib.error.HTTPError as e:
        print(f"  {repo}: closing PRs failed ({e.code}) — continuing")

    # 2. Reset main to the pre-eval SHA if it moved.
    try:
        ref = api(f"https://api.github.com/repos/{ORG}/{repo}/git/ref/heads/main")
        current = ref["object"]["sha"]
        if current == pre_sha:
            print(f"  {repo}: unchanged @ {current[:7]}"
                  + (f" (closed {closed} PRs)" if closed else ""))
            return
        api(f"https://api.github.com/repos/{ORG}/{repo}/git/refs/heads/main",
            method="PATCH", body={"sha": pre_sha, "force": True})
        print(f"  {repo}: reset {current[:7]} -> {pre_sha[:7]}"
              + (f" (closed {closed} PRs)" if closed else ""))
    except urllib.error.HTTPError as e:
        print(f"  {repo}: reset FAILED ({e.code} {e.reason})")


def main(art_dir):
    for repo in REPOS:
        try:
            reset_repo(repo, art_dir)
        except Exception as e:  # noqa: BLE001
            print(f"  {repo}: reset error — {e}")
    print("reset done (repos will rebuild their pre-eval images via CI)")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "eval-artifacts")
