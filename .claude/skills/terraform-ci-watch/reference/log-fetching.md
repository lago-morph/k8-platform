# Log Fetching

No GitHub MCP tool exposes raw workflow run logs. Fall back through this
chain — each option is one fallback for when the previous one isn't
available.

## 1. `gh` CLI (preferred when authenticated)

```sh
gh run view "$RUN_ID" --log-failed | tail -200
```

`--log-failed` filters to the failed steps only; default `--log` returns
everything (often megabytes).

For a specific job:

```sh
gh run view "$RUN_ID" --log --job "$JOB_ID"
```

## 2. `gh api` direct download

When you need the raw zip (e.g., to grep the full log offline):

```sh
gh api -H "Accept: application/vnd.github+json" \
  "repos/$OWNER_REPO/actions/runs/$RUN_ID/logs" \
  > /tmp/logs-$RUN_ID.zip
unzip -p /tmp/logs-$RUN_ID.zip | tail -300
```

The `/logs` endpoint redirects to a presigned S3 URL; `gh api` follows the
redirect. Plain `curl` against the API directly will return the redirect —
add `-L`.

## 3. Per-job inspection

If logs aren't yet uploaded (race after a recent failure):

```sh
gh api "repos/$OWNER_REPO/actions/runs/$RUN_ID/jobs" \
  --jq '.jobs[] | select(.conclusion == "failure")
        | {name, html_url, steps: [.steps[] | select(.conclusion == "failure") | {name, number}]}'
```

This returns the failed job and step names without needing the log
contents — useful for routing (e.g., is the failure in `terraform plan`
versus `state-bootstrap`?).

## 4. Check-run annotations (last resort)

If even `/jobs` is unavailable, check-runs may carry summary annotations:

```sh
mcp__github__get_commit  # use the SHA
```

The returned `check_runs[].output` often has the first error line. Less
detail than logs, but enough to classify common failures.

## Common pitfalls

- **Empty output from `--log-failed`** — the step may have been cancelled
  rather than failed. Re-fetch with full `--log`.
- **Truncation** — `gh run view` truncates very long lines. For Terraform
  plan output use `--log` and grep for `Plan:` to find the summary line.
- **Stale logs** — GitHub buffers logs; if a run just finished, retry
  after 5–10 seconds.
