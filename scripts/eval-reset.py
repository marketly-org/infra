#!/usr/bin/env python3
"""Reset marketly service repos to their pre-eval state.

For each of the 9 service repos:
  1. Close any open PRs whose title mentions Sentinel (unmerged attempts).
  2. Restore main to the SHA recorded before the eval
     (eval-artifacts/<repo>.sha).

Step 2 has two strategies:

  A. Force-push the ref (fast, rewrites history) — blocked when the repo
     has a ruleset with the non_fast_forward rule (added to the marketly
     repos 2026-09-23: 'Protect main', rules=[deletion, non_fast_forward],
     no bypass actors). Runs #28/#29/#30 all silently failed here with
     422 "Cannot force-push to this branch", so merged fixes accumulated
     on main across runs (run #30 literally evaluated an already-fixed
     search-api).

  B. Merge-based reset (ruleset-safe): create a commit whose parent is
     the current main HEAD but whose tree is the pre-eval tree, open a
     PR for it, squash-merge, delete the temp branch. This is a normal
     merge — exactly what Sentinel's own automerge does — so no rule is
     violated. History keeps the eval noise; the TREE is restored, which
     is what the planted bugs and the next run's baselines live in.

Never exits non-zero — a failed reset on one repo shouldn't sink the run,
it just gets reported (with the FULL API error body, which is how the
422-force-push root cause stayed invisible for three runs).
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


class ApiError(Exception):
    def __init__(self, code, reason, body):
        self.code = code
        self.reason = reason
        try:
            msg = json.loads(body).get("message", body)
        except Exception:
            msg = body
        super().__init__(f"{code} {reason}: {msg}")


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
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            txt = r.read().decode()
            return json.loads(txt) if txt else {}
    except urllib.error.HTTPError as e:
        raise ApiError(e.code, e.reason, e.read().decode()) from None


def close_sentinel_prs(repo):
    closed = 0
    try:
        prs = api(f"https://api.github.com/repos/{ORG}/{repo}/pulls?state=open")
        for pr in prs:
            if "sentinel" in (pr.get("title") or "").lower():
                api(pr["url"], method="PATCH", body={"state": "closed"})
                closed += 1
    except ApiError as e:
        print(f"  {repo}: closing PRs failed ({e}) — continuing")
    return closed


def get_main_sha(repo):
    ref = api(f"https://api.github.com/repos/{ORG}/{repo}/git/ref/heads/main")
    return ref["object"]["sha"]


def get_tree(repo, sha):
    gc = api(f"https://api.github.com/repos/{ORG}/{repo}/git/commits/{sha}")
    return gc["tree"]["sha"]


def merge_based_reset(repo, pre_sha, head_sha):
    """Ruleset-safe reset: PR + squash-merge a commit with the pre-eval tree."""
    pre_tree = get_tree(repo, pre_sha)
    head_tree = get_tree(repo, head_sha)
    if pre_tree == head_tree:
        return f"tree already at pre-eval state (tree {pre_tree[:10]})"
    new_commit = api(
        f"https://api.github.com/repos/{ORG}/{repo}/git/commits",
        method="POST",
        body={
            "message": f"eval: reset to pre-eval state {pre_sha[:10]}\n\n"
                       f"Restores the tree of {pre_sha} (recorded before the eval). "
                       f"Sentinel's merged fixes from this run are reverted; the "
                       f"planted bugs are findable again on the next run.",
            "tree": pre_tree,
            "parents": [head_sha],
        })["sha"]
    api(f"https://api.github.com/repos/{ORG}/{repo}/git/refs",
        method="POST",
        body={"ref": "refs/heads/eval-reset", "sha": new_commit})
    pr = api(f"https://api.github.com/repos/{ORG}/{repo}/pulls",
             method="POST",
             body={
                 "title": "eval: reset to pre-eval state",
                 "head": "eval-reset",
                 "base": "main",
                 "body": "Automated eval reset — restores the pre-eval tree via squash merge (force-push is blocked by the repo ruleset).",
             })
    api(f"https://api.github.com/repos/{ORG}/{repo}/pulls/{pr['number']}/merge",
        method="PUT",
        body={"merge_method": "squash"})
    api(f"https://api.github.com/repos/{ORG}/{repo}/git/refs/heads/eval-reset",
        method="DELETE")
    return f"merge-reset {head_sha[:7]} -> {pre_sha[:7]} via PR #{pr['number']}"


def reset_repo(repo, art_dir):
    sha_file = os.path.join(art_dir, f"{repo}.sha")
    if not os.path.exists(sha_file):
        print(f"  {repo}: no recorded SHA — skipping")
        return
    with open(sha_file) as f:
        pre_sha = f.read().strip()

    closed = close_sentinel_prs(repo)
    suffix = f" (closed {closed} PRs)" if closed else ""

    current = get_main_sha(repo)
    if current == pre_sha:
        print(f"  {repo}: unchanged @ {current[:7]}{suffix}")
        return

    # Strategy A: force-push (works when the branch is unprotected).
    try:
        api(f"https://api.github.com/repos/{ORG}/{repo}/git/refs/heads/main",
            method="PATCH", body={"sha": pre_sha, "force": True})
        print(f"  {repo}: force-reset {current[:7]} -> {pre_sha[:7]}{suffix}")
        return
    except ApiError as e:
        # Strategy B: ruleset blocks force-push — reset via merge instead.
        try:
            note = merge_based_reset(repo, pre_sha, current)
            print(f"  {repo}: {note}{suffix} [force-push was blocked: {e.code}]")
        except ApiError as e2:
            print(f"  {repo}: reset FAILED — force-push: {e}; merge-reset: {e2}")


def main(art_dir):
    for repo in REPOS:
        try:
            reset_repo(repo, art_dir)
        except Exception as e:  # noqa: BLE001
            print(f"  {repo}: reset error — {e}")
    print("reset done (repos will rebuild their pre-eval images via CI)")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "eval-artifacts")
