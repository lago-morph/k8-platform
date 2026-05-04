# Escalation Template

Use this verbatim when stopping after 3 consecutive failed fix attempts or
hitting a "no — escalate" entry in `failure-taxonomy.md`. Do not push a
4th attempt.

```
I've stopped after <N> fix attempt(s) on run <html_url>.

Latest error (from job "<job-name>" → step "<step-name>"):

  <30-line verbatim log excerpt, indented>

Attempts so far:
  1. <category> — changed <file>:<lines> to <what>. Result: <new error or "same">.
  2. <category> — changed <file>:<lines> to <what>. Result: <new error or "same">.
  3. <category> — changed <file>:<lines> to <what>. Result: <new error or "same">.

Diagnosis: <one paragraph — what the failure mode actually is, and why
each attempt didn't address it. Be honest about uncertainty.>

To unblock I need: <one specific question or action — e.g., "confirm
whether the IRSA role for ESO is supposed to have secretsmanager:GetSecretValue
on path /platform/*", or "the AWS sandbox session may have expired — please
refresh credentials and re-trigger">.
```

## Filling it in

- **Job/step names** — `gh run view $RUN_ID --json jobs --jq '.jobs[] |
  select(.conclusion=="failure") | {name, steps: [.steps[] |
  select(.conclusion=="failure") | .name]}'`
- **Log excerpt** — last 30 lines of the failed step. If the actual error
  is earlier, include the first `Error:` line plus 10 lines of context.
- **Attempts** — paste the literal `git log --oneline -3` for the fix
  commits, then describe what each tried.
- **Diagnosis** — name the failure mode in your own words. If you don't
  know, say so explicitly. Speculation framed as fact wastes user time.
- **To unblock** — must be answerable. "Help" is not answerable. "Did you
  intend X or Y?" is.

## What not to do

- Do not push a 4th attempt "just in case". The escalation is the action.
- Do not summarize the logs into your own paraphrase. Quote them.
- Do not delete or revert prior fix commits as part of escalation. Leave
  the branch in the state where the user can see what was tried.
