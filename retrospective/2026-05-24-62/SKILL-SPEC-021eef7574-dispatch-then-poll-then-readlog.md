# Spec: `dispatch-then-poll-then-readlog`

- **ID**: SKILL-SPEC-021eef7574
- **Source retrospective**: ../2026-05-24-62.md

## Intent

A `workflow_dispatch` is a three-step interaction, not one: dispatch, poll until complete, then read the relevant step's log. Each step has its own failure mode, and skipping any of them is how you end up reporting "success" against a workflow that hasn't finished or whose script silently failed.

Grounded in: dozens of workflow dispatches this session. The pattern only became reliable after the user enforced "verify evidence not exit codes." Before that, several premature `conclusion: success` claims were made against runs that hadn't finished or that had failed in ways the wrapper hid.

## Trigger

**Direct user phrases:** "dispatch X", "trigger CI", "kick the build", "run the workflow".

**Proactive triggers:** any agent action that involves `mcp__560280ab__execute` with `uuid=op_2acb005c9f3704ad` (workflow_dispatch).

**Negative triggers:** read-only ops like `list_workflow_runs` (no dispatch involved).

## Inputs

- `workflow_id` (e.g. `terraform-test.yml`)
- `ref` (branch — must exist on default branch for the workflow file)
- `inputs` (the workflow's input map)
- The expected post-condition (what the next step needs from this dispatch)

## Outputs

- A quoted log line proving the expected post-condition holds (or doesn't).
- A run URL for audit.
- A clear go/no-go for the next agent step.

## Workflow

1. **Dispatch.** `mcp__560280ab__execute uuid=op_2acb005c9f3704ad inputs={workflow_id, ref, inputs}`. The response is `null` on success (HTTP 204); on failure it returns the error body.

2. **Resolve the run ID.** Wait a few seconds, then `mcp__560280ab__execute uuid=op_e5f9dfd148ed5018 inputs={owner, repo, workflow_id, branch=ref, per_page=1}`. The newest run with `event=workflow_dispatch` AND `status=in_progress` is yours.

3. **Poll until completed.** Repeat the list_workflow_runs call until `status=completed`. Do NOT use `sleep` between polls in a tight loop — set a `run_in_background` Monitor or simply do other work and check back when a webhook arrives.

4. **Find the failed/relevant job + step.** `mcp__560280ab__execute uuid=op_2064ead94c9950bc inputs={owner, repo, run_id}` → list jobs. Each job has a steps array with name + conclusion.

5. **Download the relevant step's log.** `mcp__560280ab__execute uuid=op_c08d23e5bd6966cb inputs={owner, repo, job_id}`. The result is a giant string at `.result.output`.

6. **If the log is too big** (~50K+ chars): the MCP tool will save it to a file and return a path. Use `subagent-log-extraction` skill to pull the findings without polluting context.

7. **Grep for the specific evidence.** What line(s) confirm the post-condition? Quote at least one verbatim in the response.

8. **Report.** Either "verified by [quoted log line] in run [URL]" OR "wrapper succeeded but evidence missing — re-investigate".

## Concrete examples

### Example 1 — phase 0 apply-and-verify (handoff Step 1)

1. Dispatch `terraform-test.yml ref=main inputs={phase: base, action: apply-and-verify}`.
2. Resolve run ID via list_workflow_runs filtered to branch=main.
3. Poll: takes ~5 min.
4. Job: `Terraform (base / apply-and-verify)`. Find the `[base] apply` step.
5. Download the job log.
6. Grep for `Apply complete! Resources: 25 added, 0 changed, 0 destroyed.` AND `aws_acm_certificate_validation.cert: Creation complete`.
7. Report: "Phase 0 verified by [those two lines] in run [URL]."

### Example 2 — the silent PASS (anti-example fixed)

Run 26347839740 returned `conclusion: success` for `integration-tests.yml` `test_filter=11`. Without step 7 above, the agent reported "phase 2 verified" — wrong. WITH this skill:

7'. Grep for `PASS: PlatformSecret end-to-end:` (the script's terminal success line) AND for absence of `gave up after Ns` / `FAIL:`.
8'. Found PASS but ALSO found 3 FAILs and 4 gave-ups. Report: "Wrapper success but script lied; investigating."

## Anti-patterns

- **Polling with `sleep` in a tight loop** — wastes turns and hits the harness's anti-poll guard.
- **Reading log size and giving up** — use `subagent-log-extraction`; the log is your only ground truth.
- **Quoting the first PASS line found without scanning for FAIL** — scripts that pass-on-fail produce both.
- **Reading the WRONG step's log** — verify the step name matches the post-condition you care about.

## Acceptance criteria

1. Every workflow_dispatch is followed by poll + log-read + evidence quote.
2. No "completed" / "succeeded" / "verified" claim without a verbatim log line.
3. When the log is too big, the subagent-log-extraction skill is invoked rather than truncating.
4. The PR or status update names the run URL for audit.

## Files this skill creates / modifies

- No file modifications. This is a procedural skill.
