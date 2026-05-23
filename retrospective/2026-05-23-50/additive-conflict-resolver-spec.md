# Spec: `additive-conflict-resolver`

## Intent

When two branches both append lines to the same simple "list" file — `run.sh` test runners, `Makefile` rule lists, `requirements.txt`, `.gitignore`, etc. — `git merge` reports a conflict that's semantically not a conflict at all. Both sides should be kept; the only ambiguity is order and duplicates.

A 5-deep PR stack hit this exactly this session: every stacked PR added `run_suite tests/unit/test_<x>.sh` lines to `tests/unit/run.sh`, then a sibling PR (`#46`) inserted another line into the same region of main. All five stacked PRs went red on rebase with the identical `<<<<<<< / =======` block. The fix was mechanical — keep both sides, dedupe by string equality. Five copies of the same manual resolution would have been wasteful.

This skill encapsulates that resolution as a one-shot conflict-resolver. A fresh-context agent picks it up the next time a stack rebase hits the same pattern.

## Trigger

**Direct phrases**: "resolve the additive conflict", "merge both sides of run.sh", "this is just an append on both sides".

**Proactive triggers**:
- After a `git merge` or `git rebase` reports conflict, AND
- `git diff --name-only --diff-filter=U` returns ≤3 files, AND
- The conflicting hunks within each file consist entirely of lines that look like an "additions list" (no edits to existing lines, no semantic dependencies between added lines).

**Negative triggers**: if the conflict region contains modified-not-just-added lines, or function bodies, or YAML with structural meaning beyond a flat list, **do NOT use this skill**. Resolve manually.

## Inputs

- A repository with `git merge` or `git rebase` in conflict state.
- One or more "additive-list" files in `git status` "Unmerged" state.

## Outputs

- The same files, conflict markers removed, both sides' added lines preserved (deduplicated by exact string match), staged for the next commit.
- Stdout summary of which files were resolved and how many lines kept from each side.

## Workflow

1. Confirm the merge/rebase is in progress: `[ -f .git/MERGE_HEAD ] || [ -d .git/rebase-merge ]`. If not, exit with a message.
2. Identify unmerged files: `git diff --name-only --diff-filter=U`.
3. For each unmerged file:
   a. Sanity-check it looks "additive": every conflict hunk's HEAD and base portions consist of lines that don't appear in either side's pre-conflict context. If any hunk's HEAD or base portion includes a *modified* line (not an added one), skip this file and report it to the user — they resolve it manually.
   b. Read the file. Replace each `<<<<<<< ... ======= ... >>>>>>>` block with the concatenation of (HEAD-side non-empty lines) + (other-side non-empty lines), deduplicated by exact string equality, order-preserving (HEAD first).
   c. Write the file back.
   d. `git add <file>`.
4. Print the per-file summary: `resolved <file>: N from HEAD, M from incoming, K duplicates dropped`.
5. **Do NOT** commit. The caller decides whether to finish the merge (`git commit --no-edit`) or do additional manual edits first.

## Concrete examples

### Example 1 — `tests/unit/run.sh` additive merge

Input state (after `git merge origin/main` on PR #41's branch):

```sh
run_suite tests/unit/test_compute_gates.sh
run_suite tests/unit/test_irsa_helm_linkage.sh
run_suite tests/unit/test_iam_required_actions.sh
run_suite tests/unit/test_eks_module_defaults.sh
run_suite tests/unit/test_helm_render.sh
run_suite tests/unit/test_post_comment.sh
run_suite tests/unit/test_kyverno_policy_lint.sh
<<<<<<< HEAD
run_suite tests/unit/test_chainsaw_kind_config.sh
=======
run_suite tests/unit/test_diag_component.sh
>>>>>>> origin/main
```

Skill output:

```sh
run_suite tests/unit/test_compute_gates.sh
run_suite tests/unit/test_irsa_helm_linkage.sh
run_suite tests/unit/test_iam_required_actions.sh
run_suite tests/unit/test_eks_module_defaults.sh
run_suite tests/unit/test_helm_render.sh
run_suite tests/unit/test_post_comment.sh
run_suite tests/unit/test_kyverno_policy_lint.sh
run_suite tests/unit/test_chainsaw_kind_config.sh
run_suite tests/unit/test_diag_component.sh
```

Console: `resolved tests/unit/run.sh: 1 from HEAD, 1 from incoming, 0 duplicates dropped`.

### Example 2 — `.gitignore` with duplicates

Input:

```
*.tfstate
*.tfstate.backup
<<<<<<< HEAD
.terraform/
__pycache__/
*.pyc
=======
__pycache__/
.terraform.lock.hcl
>>>>>>> origin/main
```

Output:

```
*.tfstate
*.tfstate.backup
.terraform/
__pycache__/
*.pyc
.terraform.lock.hcl
```

Console: `resolved .gitignore: 3 from HEAD, 2 from incoming, 1 duplicate dropped`.

## Anti-patterns

- **Do not run this on conflict blocks that include modified existing lines.** This session's `run.sh` conflict was safe because both sides were pure-add. A function body that both branches edited differently is a real conflict; flattening with this skill silently picks one side's edits over the other.
- **Do not commit automatically after resolving.** The caller may want to inspect the result or add more changes to the merge commit. The skill stages files; commit is the caller's call.
- **Do not skip the sanity-check pass.** A YAML file where both sides "added" a key under the same parent is NOT a flat-list conflict — the key order may matter or one side may have changed an existing key. Use the sanity-check to filter.
- **Do not preserve duplicates.** A `run_suite test_X` line that appears on both sides should appear once in the output. Otherwise the next merge regenerates the same conflict in a new form.

## Acceptance criteria

1. Running the skill on Example 1 produces exactly Example 1's expected output, with stdout reporting the correct counts.
2. Running on a non-additive conflict (e.g. both sides modify the same function body) **skips that file** with a `manual resolution required: <reason>` message.
3. Idempotent: running twice in a row produces no diff after the first run.
4. The skill exits non-zero if any sanity-check fails on any file (so a `git commit` immediately after isn't possible if anything was skipped).
5. No external dependencies beyond Python 3 stdlib + `git`.

## Files this skill creates / modifies

- `<unmerged-file>` — overwritten with the resolved content for any file that passes the additive sanity-check.
- Git index — `git add` is run on each resolved file.

No new files are created; no commit is made.
