#!/usr/bin/env python3
"""
Post a Terraform run summary as a comment on the triggering PR or commit.

Reads plan/apply/destroy output files from RUNNER_TEMP, builds a formatted
GitHub Markdown comment, then posts it via the GitHub API using the built-in
GITHUB_TOKEN from the workflow environment.
"""

import json
import os
import pathlib
import sys
import urllib.request
import urllib.error

TMP = pathlib.Path(os.environ["RUNNER_TEMP"])
REPO = os.environ["GITHUB_REPOSITORY"]
SHA = os.environ["GITHUB_SHA"]
REF = os.environ["GITHUB_REF_NAME"]
EVENT = os.environ["GITHUB_EVENT_NAME"]
TOKEN = os.environ["GH_TOKEN"]
MODE = os.environ.get("RUN_MODE", "plan-only")
RUN_URL = (
    f"https://github.com/{REPO}/actions/runs/{os.environ.get('GITHUB_RUN_ID', '')}"
)

OWNER = REPO.split("/")[0]

MAX_LINES = 100  # truncate long outputs to keep the comment readable


def read_output(filename: str) -> str | None:
    p = TMP / filename
    if not p.exists():
        return None
    text = p.read_text(errors="replace")
    lines = text.splitlines()
    if len(lines) > MAX_LINES:
        lines = [f"_(output truncated — showing last {MAX_LINES} of {len(lines)} lines)_"] + lines[-MAX_LINES:]
    return "\n".join(lines)


def outcome_emoji(outcome: str | None) -> str:
    return {"success": "✅", "failure": "❌", "skipped": "⏭️", "cancelled": "🚫"}.get(
        outcome or "", "❓"
    )


def section(title: str, filename: str, outcome: str | None = None) -> str:
    content = read_output(filename)
    emoji = outcome_emoji(outcome)
    if content is None:
        return f"\n### {emoji} {title}\n_not run_\n"
    return (
        f"\n### {emoji} {title}\n"
        f"<details><summary>View output</summary>\n\n"
        f"```\n{content}\n```\n\n"
        f"</details>\n"
    )


def build_body() -> str:
    plan_base = os.environ.get("PLAN_BASE_OUTCOME")
    plan_mgmt = os.environ.get("PLAN_MGMT_OUTCOME")

    parts = [
        "## Terraform Test Results\n",
        f"**Trigger:** `{EVENT}` &nbsp;|&nbsp; "
        f"**Branch:** `{REF}` &nbsp;|&nbsp; "
        f"**Mode:** `{MODE}` &nbsp;|&nbsp; "
        f"[View run]({RUN_URL})\n",
        section("Base — Plan", "base-plan.txt", plan_base),
        section("Base — Apply", "base-apply.txt"),
        section("Management — Plan", "mgmt-plan.txt", plan_mgmt),
        section("Management — Plan (post-base apply)", "mgmt-plan-post-base.txt"),
        section("Management — Apply", "mgmt-apply.txt"),
        section("Management — Destroy", "mgmt-destroy.txt"),
        section("Base — Destroy", "base-destroy.txt"),
    ]
    return "".join(parts)


def gh_api(method: str, path: str, body: dict | None = None) -> dict | list | None:
    url = f"https://api.github.com{path}"
    data = json.dumps(body).encode() if body else None
    req = urllib.request.Request(
        url,
        data=data,
        method=method,
        headers={
            "Authorization": f"Bearer {TOKEN}",
            "Accept": "application/vnd.github+json",
            "Content-Type": "application/json",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    try:
        with urllib.request.urlopen(req) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as exc:
        print(f"GitHub API error {exc.code} for {method} {path}: {exc.read().decode()}", file=sys.stderr)
        return None


def find_pr_number() -> int | None:
    result = gh_api("GET", f"/repos/{REPO}/pulls?head={OWNER}:{REF}&state=open")
    if result and isinstance(result, list) and result:
        return result[0]["number"]
    return None


def main() -> None:
    comment_body = build_body()

    pr_number = find_pr_number()
    if pr_number:
        print(f"Posting comment to PR #{pr_number}")
        endpoint = f"/repos/{REPO}/issues/{pr_number}/comments"
    else:
        print(f"No open PR found for branch {REF!r}; posting commit comment on {SHA[:7]}")
        endpoint = f"/repos/{REPO}/commits/{SHA}/comments"

    result = gh_api("POST", endpoint, {"body": comment_body})
    if result:
        print(f"Comment posted: {result.get('html_url', '(no URL)')}")
    else:
        print("Failed to post comment (see stderr above)", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
