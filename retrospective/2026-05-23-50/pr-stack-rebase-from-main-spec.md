# Spec: `pr-stack-rebase-from-main`

## Intent

When a sibling PR off `main` merges and creates conflict with a deep PR stack you're maintaining, the mechanical work — for each branch in stack order: checkout, merge main, resolve conflicts, push — is repetitive, error-prone, and easy to do on the wrong branch. (This session: I tried to merge main into stack-branch #41, got confused because my checkout had silently aborted on a dirty tree, and ended up merging into the wrong branch. Had to abort and start over.)

This skill scripts the loop with the safety properties baked in: confirm clean working tree before each checkout; iterate in stack-base-first order; report per-branch status before pushing; force-confirm before any force-push.

## Trigger

**Direct phrases**: "rebase the stack onto main", "the stack PRs need to pick up the new main", "fix the merge conflicts on the open PRs", "sync the stack with main".

**Proactive trigger**: a sibling PR just merged and the user has open stacked PRs whose CI started turning red. Offer this skill before the user asks.

**Negative trigger**: if the stack is currently in a clean state and the user just wants to inspect, don't run anything.

## Inputs

- A repository with the stack branches checked out locally (or fetchable from origin).
- A stack order, either supplied explicitly or inferred from PR `base` relationships.
- Optionally, an `--additive-resolver` flag pointing at the `additive-conflict-resolver` skill for known-safe additive conflicts.

## Outputs

- Each branch in the stack updated to have its tip merged with current `origin/main`, with conflicts resolved.
- Each branch pushed to origin (no force-push by default — uses regular merge commits, not rebase).
- A summary per branch: commit SHA before and after, files conflicted, files resolved automatically vs manually.

## Workflow

1. **Sanity check**:
   - `git rev-parse --abbrev-ref HEAD` to remember the starting branch.
   - `git status --porcelain` must be empty. If not, stop and tell the user to commit or stash.
   - `git fetch origin main` to ensure local main reference is current.
2. **Resolve stack order**. If supplied, use that. If not, infer from PR base relationships via `gh pr list` or `mcp__github__list_pull_requests`. Order must place the deepest-base-on-main branch first (so when you merge main into the second branch, it doesn't conflict with the first branch's local-only changes).
3. **For each branch in order**:
   a. `git checkout <branch>` — if checkout aborts due to dirty working tree, stop and report. **Do not proceed silently.**
   b. `git pull --ff-only origin <branch>` to ensure local matches remote.
   c. `git merge origin/main --no-ff -m "merge main: <one-line reason>"`. Capture exit code.
   d. If exit 0 (clean merge or no-op): record SHA, move on.
   e. If exit !=0 (conflict): list unmerged files. For each file that matches a known-additive pattern (e.g., `tests/unit/run.sh`, `.gitignore`), invoke the additive resolver. For other files, **stop and prompt the user** with the conflict — do not guess.
   f. Once all files resolved, `git commit --no-edit`.
   g. `git push origin <branch>`. Default to a regular push (no force). If a non-fast-forward is reported, abort and surface to the user — never force-push without explicit instruction.
4. **Restore the starting branch** at the end.
5. **Print the summary table**.

## Concrete examples

### Example 1 — sibling PR merged, stack needs sync (this session's scenario)

State before:
- `main` advanced by PR #46 which added `run_suite tests/unit/test_diag_component.sh` to `tests/unit/run.sh`.
- Stack branches `feat/phase-2a-chainsaw-infra` (#41), `feat/phase-2a-platform-secret` (#42, base=#41), `feat/phase-2a-argocd-bootstrap` (#43, base=#42), `feat/phase-2a-extended-tests` (#44, base=#43), `chore/handoff-phase-2a-progress` (#45, base=#44). Each one adds its own `run_suite` line to the same file.

Skill invocation:
```
pr-stack-rebase-from-main \
  --branches feat/phase-2a-chainsaw-infra,feat/phase-2a-platform-secret,feat/phase-2a-argocd-bootstrap,feat/phase-2a-extended-tests,chore/handoff-phase-2a-progress \
  --additive-resolver
```

Per-branch action: checkout, merge main, additive-resolve `tests/unit/run.sh`, commit, push. No other conflicts arise.

Final summary:
```
feat/phase-2a-chainsaw-infra:     422fda1 → db00fb8 (resolved run.sh)
feat/phase-2a-platform-secret:    476d0d1 → 092d49e (resolved run.sh)
feat/phase-2a-argocd-bootstrap:   ec8a08a → 054d453 (resolved run.sh)
feat/phase-2a-extended-tests:     2cf110a → f6bf126 (resolved run.sh)
chore/handoff-phase-2a-progress:  061eb36 → 6340dec (resolved run.sh)
```

### Example 2 — conflict in a non-additive file → stop and prompt

If during step 3 the conflict is in `terraform/management/helm.tf` (a real-content edit, not a list append), the skill stops at that branch and reports:

```
feat/phase-2a-argocd-bootstrap: CONFLICT in terraform/management/helm.tf
  HEAD added an `argocd_bootstrap` block at line 230.
  origin/main rewrote the `kyverno_audit_policies` block at line 207.
  These overlap. Stopping. Please resolve manually, then re-run with
  --resume.
```

## Anti-patterns

- **Never force-push during the loop.** If a non-fast-forward shows up, stop. The user may have made their own changes on origin that need to be reconciled.
- **Never proceed past a dirty working tree.** This session's first attempt got confused because `git checkout` silently aborted on a dirty tree and the merge ran on the wrong branch.
- **Never reorder the stack.** Process in base-first order. Mid-stack rebasing leaves the upper PRs based on stale commits.
- **Never auto-resolve a non-additive conflict.** Even if the resolver supports more patterns later, the default must be "stop and ask" for anything that isn't pure-append.

## Acceptance criteria

1. Run on a 3-deep stack with a clean additive conflict in one file across all three branches: all three branches updated and pushed in one invocation, no force-pushes.
2. Run with a non-additive conflict on the middle branch: skill stops there, reports the conflict, leaves the lower branch already-merged, and exits non-zero.
3. Run twice in a row (after a successful first run): second run is a no-op (each branch's `merge origin/main` is fast-forward or already-merged).
4. Starting branch is restored at the end.
5. Summary table reports SHA before/after per branch.

## Files this skill creates / modifies

- Local git refs (branch tips) for each branch in the stack.
- Remote tracking refs after push.
- No new files in the working tree.
- Optionally: a `.pr-stack-rebase.log` file in the repo root with the per-branch summary, for resumption after manual conflict resolution.
