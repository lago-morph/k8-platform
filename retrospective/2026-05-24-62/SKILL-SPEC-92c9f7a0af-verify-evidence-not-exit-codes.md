# Spec: `verify-evidence-not-exit-codes`

- **ID**: SKILL-SPEC-92c9f7a0af
- **Source retrospective**: ../2026-05-24-62.md

## Intent

After an action that touches a layered system (workflow dispatch, kubectl apply, ArgoCD sync, PR merge), do not trust the outermost wrapper's success indicator. Read the actual evidence — log lines, status conditions, API response bodies — and quote them before reporting an outcome. The skill captures and enforces this discipline.

Grounded in: integration-tests run 26347839740. The workflow's `conclusion: success` was true; the script inside passed-on-failure due to missing `set -e` and a `$UID` shadow bug. I read the wrapper status, said "✅ phase 2a genuinely verified", and was wrong. Four wait_for timeouts, one ResourceNotFoundException, one `FAIL: expected … got ''` — all hidden behind the wrapper's green tick.

## Trigger

**Direct user phrases:**
- "Did that actually work?"
- "Verify [X] really happened"
- "How do you know?"
- "Check that for real"

**Proactive triggers (skill should activate without being asked):**
- Just after a `workflow_dispatch` returns success
- Just after `git push` returns 0
- Just after a `merge_pull_request` MCP call returns
- Before reporting an outcome to the user
- Before crossing a state boundary in a multi-step plan (e.g., before moving from Step N to Step N+1 in any procedure)

**Negative triggers (do not activate):**
- Pure-read operations whose output is the evidence itself (e.g., `kubectl get`)
- Local-only operations the agent observed directly (e.g., file edit just made via the Edit tool)

## Inputs

- The kind of action just taken (workflow_dispatch / kubectl apply / git push / merge / etc.)
- The handle returned by the action (run ID, commit SHA, PR number)
- The expected post-condition (what the agent claims is now true)

## Outputs

- A verbatim-quoted log line, status condition, or API response that proves the post-condition holds.
- A "verified" or "still-unverified" status flag — never an unqualified "done".
- Optional: a follow-up action recommendation if the evidence contradicts the expected post-condition.

## Workflow

1. **Identify the wrapper.** What is the outer success indicator (workflow conclusion, push exit code, merged: true)? Note it.
2. **Identify the underlying evidence.** What inner artifact actually demonstrates the post-condition? Use the table below.
3. **Fetch the evidence.** Use the appropriate tool (download_job_logs, pull_request_read, kubectl-via-workflow, ext-aws describe, etc.).
4. **Grep for the specific PASS line(s).** Quote them verbatim in the agent's response. If the line is not present, the action did NOT achieve the post-condition.
5. **Report.** Either "verified by [quoted evidence]" OR "wrapper claims success but evidence missing — re-investigate".

### Evidence table

| Action | Inner evidence to fetch |
|---|---|
| `workflow_dispatch` | The named step's log lines for the assertion in question. Quote at least one. |
| `git push` | Either grep the push output for `<branch> -> <branch>` OR re-resolve `HEAD` via `git rev-parse` and compare to expected SHA. |
| PR merge | `pull_request_read method=get` → confirm `merged: true` AND `merge_commit_sha` is a real commit. |
| `kubectl apply` (via workflow) | Follow-up dispatch reading `.status.conditions` of the applied object via jsonpath. |
| ArgoCD sync | `kubectl get application … -o jsonpath='{.status.sync.status}/{.status.health.status}'` returns `Synced/Healthy`. |
| AWS resource expected to exist | `aws … describe-… --query` returns the expected ARN/ID. |
| Bash script run in CI | Read the script's own `PASS:` / `FAIL:` / `gave up` lines, not the workflow step's conclusion. Scripts can pass-on-fail when not strict. |
| Test claims green | Open the test runner's per-assertion lines, not the wrapper's `OK 5 tests passed` count. |

## Concrete examples

### Example 1 — workflow_dispatch verification (the actual session bug)

**Input:** I just dispatched integration-tests.yml `test_filter=11` (run 26347839740). Wrapper conclusion = `success`. I plan to tell the user "phase 2 verified."

**Workflow:**

1. Wrapper: `conclusion: success` (noted, NOT trusted).
2. Inner evidence: the `Run integration tests` step's log MUST contain `PASS: PlatformSecret end-to-end:` (script's terminal success line) AND must NOT contain `gave up after Ns` or `FAIL:` lines.
3. Fetch: `mcp__560280ab-..._execute` op `op_c08d23e5bd6966cb` (download_job_logs) with the job_id from list_jobs.
4. Grep:
   ```
   FOUND: PASS: PlatformSecret end-to-end: apply → ASM + K8s Secret → rotation → delete
   ALSO FOUND: ✗ PlatformSecret/integ-platsec-… Ready=True ← gave up after 183s
   ALSO FOUND: bash: line 78: UID: readonly variable
   ALSO FOUND: FAIL: expected 'hello-from-integration-…', got ''
   ```
5. Report: **NOT verified.** The script printed PASS but ALSO printed three failure indicators. The script is lying due to missing `set -e`. Re-investigate.

(In the actual session this verification was not done; the agent reported "verified" and the user had to push back. Adopting this skill would have caught the lie before reporting.)

### Example 2 — PR merge verification (would have prevented circular bug in Step 0)

**Input:** Handoff Step 0 says "merge PR #61, confirm via `pull_request_read merged: true`."

**Workflow:**

1. Wrapper: there is none for the user clicking merge — but the agent's instruction is to confirm.
2. Inner evidence: `pull_request_read method=get pullNumber=61` returns `merged: true` AND `merge_commit_sha` is non-null AND the SHA appears in `git log main` after pull.
3. Fetch: the MCP call.
4. Grep: `merged: true` in the returned JSON.
5. Report: **verified.** OR: **still draft — ask user to merge before proceeding.**

This skill closes the loop the handoff opened (Step 0 #4): without it, an agent could read `merged: false`, assume "in progress, I'll check later", and proceed to Step 1 — which is exactly the failure mode the handoff prohibits.

## Anti-patterns

- **Reporting "completed" / "verified" without quoting the evidence.** If the response doesn't have a verbatim quote, the verification didn't happen.
- **Trusting `conclusion: success` from `workflow_dispatch` for any script-driven workflow.** Scripts can pass-on-fail. Always read the script's own output.
- **Trusting `merged: true` from a stale PR read.** Re-fetch after the user is told to merge.
- **Sampling evidence selectively.** If the log contains both PASS and FAIL lines, both count. Report the contradiction, don't pick the friendlier one.
- **Reading evidence into context but not quoting it in the response.** The user can't audit your verification without seeing the evidence.

## Acceptance criteria

1. Every "done", "verified", "successful" claim in the agent's response is followed by a verbatim quote (≤2 lines) from the underlying evidence.
2. When evidence is missing, the response says so explicitly ("wrapper succeeded but evidence not found at expected path — re-investigating") rather than assuming success.
3. The skill prefers fast verification (re-fetch one log line) over expensive verification (re-run the entire workflow) where both are valid.
4. Subsequent steps in a multi-step procedure do NOT begin until the prior step's verification quote is in the response.
5. The skill is invoked transparently — the user sees the agent quoting evidence, not just running the verification silently.

## Files this skill creates / modifies

- No file modifications. This is a behavioural skill — its output appears in agent responses.
- (Optional, future) `.claude/skills/verify-evidence-not-exit-codes/examples/` — a directory of quoted-evidence-pattern examples for common action types.
