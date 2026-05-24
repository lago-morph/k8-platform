# Spec: `manual-dispatch-as-kubectl-bridge`

## Intent

When the agent needs to run a kubectl/AWS/ArgoCD command against a live cluster but has no direct cluster access (sandbox doesn't have AWS creds, no kubeconfig), author a manual-dispatch workflow that takes the command's intent as an input and prints the output to the workflow log. Treat it as a remote-exec channel.

Grounded in: `integration-tests.yml` (PR #57) was originally authored as exactly this — a way to run `tests/integration/*.sh` against the live cluster from the sandbox. `phase-2-diagnose.yml` (PR #60) extended the pattern for diagnostic reads. PR #58 added `mode=teardown-phase-2 / verify-absent / rebuild` further extending the pattern. The session never directly accessed the cluster; everything went through these bridges.

## Trigger

**Direct user phrases:**
- "Run a kubectl command on the cluster"
- "Sync the ArgoCD app"
- "Check the status of X on the live cluster"

**Proactive triggers:**
- Agent needs cluster state that isn't surfaced by an existing diagnostic
- Agent needs to apply, delete, or sync something on the live cluster
- `ext-aws` / `ext-argocd` / `ext-kubernetes` not yet installed for the operation in question

**Negative triggers:**
- `ext-aws` / `ext-argocd` is installed and the operation is in scope — use the direct bridge instead
- The operation can be done purely by ArgoCD GitOps sync (just push a manifest, let Argo apply)

## Inputs

- The intent (what command(s) to run)
- The workflow file path to author or extend
- Required permissions (AWS secrets, kubectl access)
- Read-only vs mutating (governs `permissions:` block and concurrency)

## Outputs

- A new (or extended) `.github/workflows/<purpose>.yml` with:
  - `workflow_dispatch:` only
  - Necessary AWS env from secrets
  - `aws eks update-kubeconfig` step
  - The command(s) under named, greppable steps
  - For mutating ops: explicit pre-flight + cleanup
- A run URL where the output is captured
- A quoted finding back to the user / next agent step

## Workflow

1. **Decide: new file or extend existing?** New file for diagnostic / one-off. Extend `integration-tests.yml` with a `mode` input for ops that are part of a lifecycle (test / teardown / verify-absent / rebuild).

2. **Author the workflow.** Boilerplate:
   ```yaml
   name: <purpose>
   on:
     workflow_dispatch:
       inputs:
         <args>:
           description: <...>
           required: false
   concurrency:
     group: <purpose>-live
     cancel-in-progress: false   # mutations should never be cancelled mid-flight
   permissions:
     contents: read
   jobs:
     run:
       runs-on: ubuntu-24.04
       env:
         AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}
         AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
         AWS_REGION: ${{ secrets.AWS_REGION }}
         AWS_DEFAULT_REGION: ${{ secrets.AWS_REGION }}
       steps:
         - uses: actions/checkout@v4
         - name: Configure kubectl
           run: |
             aws sts get-caller-identity
             aws eks update-kubeconfig --name k8-platform-mgmt --region "${AWS_REGION}"
         - name: <named step for the operation>
           run: |
             # the command
   ```

3. **For mutating ops:** add a pre-flight inventory step (dump what you're about to modify) and an explicit cleanup-on-failure step. The order matters — claims before XRDs before Compositions, etc.

4. **For read-only diagnostics:** add the line `permissions: contents: read` and double-check no step mutates state.

5. **Commit on a branch + push + dispatch against the branch ref.** Note: workflow_dispatch requires the workflow file to exist on the default branch before non-default refs can dispatch it. Chicken-and-egg — usually means a small workflow-only PR to merge first.

6. **Read the output via `dispatch-then-poll-then-readlog`.** Quote findings.

## Concrete examples

### Example 1 — `phase-2-diagnose.yml` (the actual session artifact)

Read-only workflow at `.github/workflows/phase-2-diagnose.yml`. Inputs: none. Steps:

- Configure kubectl
- Bug 3 investigation: dump ArgoCD applications + describe per-app
- Bug 4 investigation: dump providers + functions + ESO + apply throwaway probe claim
- AWS-side ASM + IRSA check

Dispatched after merge. Output: 155K-char log. Subagent extraction surfaced root causes for Bug 3 and Bug 4 simultaneously.

### Example 2 — `integration-tests.yml mode=teardown-phase-2` (PR #58)

Mutating workflow at the same file, extended with a `mode` input. The teardown mode:

1. Deletes PlatformSecret claims (cascade-cleanup via ASM Composition `deletionPolicy: Delete`)
2. Waits for composites + managed resources gone
3. Patches the two phase-2 ArgoCD apps to disable selfHeal
4. Cascade-deletes the apps with foreground finalizer

Concurrency-grouped to `integration-tests-live` so two operators can't race.

## Anti-patterns

- **Author a mutating workflow with `permissions: contents: read`.** Mismatch — the workflow might silently fail on permission errors. Mutating workflows need `contents: write` if they git-push, or no permissions block if pure cluster-side.
- **Author a mutating workflow without concurrency control.** Two operators dispatching simultaneously corrupts state.
- **Mix read-only and mutating ops in the same workflow without explicit modes.** Hard to reason about which dispatch is safe.
- **Forget the workflow_dispatch-needs-default-branch rule.** You'll dispatch and get HTTP 404 / "Not Found".
- **Hard-code account-specific IDs in the workflow.** Use secrets + the well-known cluster name `k8-platform-mgmt`.
- **No `aws sts get-caller-identity` pre-flight.** First sign of stale credentials is a confusing kubeconfig error 3 steps later.

## Acceptance criteria

1. Every workflow has `workflow_dispatch:` as its only trigger (no `push:` or schedule for these).
2. Read-only workflows have `permissions: contents: read`.
3. Mutating workflows have concurrency-group with `cancel-in-progress: false`.
4. Every workflow runs `aws sts get-caller-identity` pre-flight.
5. Every workflow uses the fixed cluster name `k8-platform-mgmt` (no terraform output dependency).

## Files this skill creates / modifies

- `.github/workflows/<purpose>.yml` — one per logical purpose
- (Optional) `ai/dispatch-bridges.md` — index of bridge workflows + what they do
