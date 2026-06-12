# environment.md — sandbox & environment capability profile

**Audience: AI agents.** The single authoritative description of what a session
running in the Claude Code remote sandbox can and cannot do against this repo's
environment. Created 2026-06-10 (forensics round 2) because capability facts were
scattered across rules and skills, and false capability premises repeatedly
propagated into plans (forensics: D9). **Verify here before declaring anything
unavailable, unreachable, or read-only — and verify by probing, not by assuming.**

Facts below are durable mechanics. Anything account-specific is ephemeral by
design — discover it live, never hardcode it (enforced:
`tests/unit/test_no_account_id_hardcoded.sh`).

## 1. The AWS account (ephemeral by design)

- The account **rotates between sessions**. Run `scripts/whereami.sh` first.
  Assume every phase is `not applied` until the live API proves otherwise — no
  state backend, no EKS, no IRSA/ACM/Cognito; only the Route53 hosted zone.
- Constraints (Pluralsight sandbox): us-east-1/us-west-2; small instance types;
  EC2 quota; details in `ai/testing-guidelines.md`.
- Account-derived values (account ID, FQDNs, ARNs, endpoints, cert IDs) are
  **not durable** — never hardcode in tracked files; run URLs and commit SHAs
  are fine.

## 2. Credentials

- **CI always has AWS creds** via three GHA repo secrets (`AWS_ACCESS_KEY_ID`,
  `AWS_SECRET_ACCESS_KEY`, `AWS_REGION`); everything else (state bucket, lock
  table, root domain, test creds) is auto-computed by
  `.github/workflows/terraform-test.yml`.
- Do **not** assume the GHA secrets are stale: dispatch a cheap probe
  (`terraform-test.yml` `phase=test action=test-e2e`, or any `apply-and-verify`
  which fails fast on `InvalidClientTokenId`) and read the result. "Stale" is a
  verified state, never a default.
- The sandbox itself may or may not hold AWS credentials, and their scope has
  varied across sessions — check with `aws sts get-caller-identity`, don't
  assume either way. **Policy regardless of scope:** credentials are for
  *reading/diagnosing*. Mutating platform state by hand to clear a blocker or
  pass a check is banned (AGENTS.md done-contract); mutations land via
  CI/GitOps from committed source. (Structural narrowing of sandbox creds is
  planned — `ai/LESSONS.md` S2.)
- The git push credential accepts **branch refs only** (no tags) and lacks the
  `workflow` OAuth scope — pushes touching `.github/workflows/**` are refused;
  route workflow-file writes through the `ext-github` skill (jentic bridge).

## 3. Network egress

- All outbound HTTPS passes a **TLS-terminating gateway** that strictly
  verifies the upstream certificate. Reachable: hosts presenting
  publicly-trusted certs with matching SANs. **Unreachable (503): private-CA
  endpoints — including every EKS kube-API** — and SAN-mismatched services.
- Diagnose with `openssl s_client`: `unable to get local issuer certificate` =
  private CA (route the work through CI); a SAN-list error = fixable cert gap.
- Blocked API surfaces are bridged by skills: GitHub Actions REST →
  `ext-github`; generic APIs → `external-api-bridge`; kube-API → CI workflows
  (`kube-diagnose.yml`) or the SSM relay (`sandbox-kubectl-access`).

## 4. Kubernetes & platform access

- No direct kube-API from the sandbox (see §3). Options, in order: CI
  workflows; the SSM relay; or diagnose via the **cloud API** — ENI/IP counts
  for pod density, CloudWatch for load, EKS API for cluster/nodegroup health.
  Label cloud-API-derived facts as such.
- **ArgoCD**: Terraform exposes `argocd_admin_password` / `argocd_server_url`
  as outputs precisely so a session can drive it (`argocd login` + `app
  sync`/`get`) — read them from state via CI, never depend on
  `argocd-initial-admin-secret` or hand the owner a "click Sync" step.

## 5. Toolchain & capability checklist

- The SessionStart hook installs the pinned CLI toolchain (`versions.env`):
  yq, crossplane, aws, helm, argocd, kubectl, session-manager-plugin; dockerd
  is started in the background (may need a few seconds).
- Before reporting any tool/capability "unavailable": check PATH and common
  bins; check for a stopped daemon (`pgrep`, `service start`); try the
  one-line install. `which X` returning nothing is an unanswered question.
  The record shows "unavailable" diagnoses made without probing were wrong
  repeatedly (forensics R3).

## 6. CI interaction mechanics

- Heavy workflows (`chainsaw.yml`, `terraform-test.yml`, `integration-tests`,
  `live-verify`) are `workflow_dispatch`-only by design (cost); light static
  gates run on push. `chainsaw-verify.yml` / `live-evidence-verify.yml` gate
  PRs by finding a prior green run **for the exact HEAD SHA** — finalize all
  commits *before* dispatching, or the gate can never match.
- **Never foreground-poll a run** (every tool call re-uploads the whole
  conversation). Dispatch exactly one background waiter (`Bash`
  `run_in_background`, `until status=completed`), work on other durable tasks
  meanwhile. Use `Monitor` only for genuine multi-event streams.
- Webhooks drop events occasionally and never deliver during sandbox
  suspension: at **ETA+50% silence**, make ONE direct status query; after any
  resume-from-suspension, first re-query every in-flight dispatch.
- `mergeable_state: unstable` = non-blocking checks pending/failing, not
  blocked — check before deferring a merge.
- **Unauthenticated `api.github.com` calls from the sandbox rate-limit within
  minutes** (verified 2026-06-10: HTTP 403 rate-limit after ~6 polls). Poll
  runs via the authenticated GitHub MCP tools or timed background wake-ups —
  never raw curl loops.
- Oversized GitHub MCP results (e.g. `actions_list`, ~380 KB) are auto-saved
  to a tool-results file path printed in the error; parse THAT file with
  `python3`/`json` instead of re-calling the tool with smaller paging — the
  re-call usually returns the same oversized payload.

## 7. Subagent harness limits

- Subagents may lack tools the lead has (notably `Agent`/Task in past
  sessions); design fan-outs so subagents don't need to re-delegate.
- Worktree isolation is path-based: a subagent writing **absolute paths** or
  running `git checkout -B` can mutate the main worktree/HEAD. Brief subagents
  with relative paths inside their worktree and no branch-moving git commands.

## 8. AWS behavioral facts that bit before

- `aws iam simulate-principal-policy` returns `implicitDeny` for everything on
  a freshly-modified IRSA role — it cannot prove a narrowing; prove IAM
  tightenings on the live CREATE path plus a static source lint.
- EKS `CreateNodegroup` validates the service-linked role via `iam:GetRole` on
  `role/aws-service-role/eks*…` — scope IAM narrowings accordingly (the
  zero-node-spoke regression, PR #213).
- AWS Resource Groups Tagging rejects non-ASCII (em-dash) in tag values;
  Secrets Manager deletion is eventually consistent (poll, never one-shot).
  Both are covered by `scripts/pre-chainsaw-audit.sh`.

## 9. Updating this file

Add a fact when a capability premise is verified (probe output, run ID) and it
will recur; correct, don't append contradictions. Behavioral/judgment rules do
NOT belong here — this file is facts about the environment
(`ai/LESSONS.md` §3.1 routing).
