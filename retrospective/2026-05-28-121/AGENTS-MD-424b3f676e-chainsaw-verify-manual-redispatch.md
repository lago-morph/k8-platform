# agent instruction

**After dispatching `chainsaw.yml` and confirming it completed green, if the corresponding `chainsaw-verify` workflow already ran on the same SHA (via push trigger) and went red, manually re-dispatch `chainsaw-verify` via `workflow_dispatch`.** The verifier does not have a `workflow_run` listener — it does not auto-re-fire when chainsaw completes. Without the manual re-dispatch the PR check stays red even though chainsaw is genuinely green.

*Grounded in: PR #111 (2026-05-28) — chainsaw-verify ran on push of `ef410ac` while chainsaw was still in flight; required a manual `workflow_dispatch` of `chainsaw-verify.yml` to flip the PR check from red to green.*

# justification

`chainsaw-verify.yml` is triggered on `push` (with path filters) and `workflow_dispatch`. There is no `workflow_run` listener that auto-fires when `chainsaw.yml` completes. The intended workflow is: dispatch chainsaw, wait for green, push the commit, verifier runs on push, finds the green run, ✅. The actual flow this session: push, verifier runs on push, chainsaw is still in flight (10 min behind), verifier finds no cached green run, ❌. Chainsaw later completes green — but the verifier doesn't know. The PR check `Verify chainsaw ran green on this commit` stays red, blocking merge even though the work is genuinely green. The fix is one `workflow_dispatch` call to `chainsaw-verify.yml` with the same `ref`. Three lines of `ext-github` invocation. Without the rule, the next agent will repeat the diagnostic loop ("chainsaw is green; why is the PR red?") and the user will see a red PR check on otherwise-green work. The marginal cost is one tool call per chainsaw-then-verify cycle.
