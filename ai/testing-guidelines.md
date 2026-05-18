# Testing Guidelines — k8-platform

This document describes (a) the Pluralsight sandbox constraints the project
operates under, (b) the **phase-by-phase development workflow** the agent is
expected to follow, and (c) the inner debug loop used to drive a single phase
to "verified" state. Together they replace the old monolithic
`apply-and-destroy` story.

The agent reads this file whenever the user says "work on phase N" or any
equivalent phrasing. `CLAUDE.md` points here.

---

## 1. Sandbox Constraints (Pluralsight AWS)

**Source:** https://help.pluralsight.com/hc/en-us/articles/24425443133076-AWS-cloud-sandbox
(requires Pluralsight authentication). Verify against that page before
relaxing any limit below.

### Session

| Constraint | Value |
|---|---|
| Session duration | **4 hours** — the account and all resources are destroyed automatically |
| Re-use across sessions | Not possible — each session is a fresh AWS account |
| End-of-session cleanup | **Automatic**. The agent does **not** run `destroy` to "tidy up" — see §4. |

**Implication:** Terraform state in S3 lives only inside the current sandbox
session. The CI bootstrap step recreates the state bucket + DynamoDB lock
table on every new session.

### EC2

| Constraint | Value |
|---|---|
| Allowed families/sizes | t2 / t3 / t3a / t4g — only `micro`, `small`, `medium` |
| Max EBS volume | 100 GB per volume |
| Max concurrent instances | **9** total across all services (counts stopped, excludes terminated) |

Management cluster default: `t3.medium × 2` (`desired=2, min=1, max=3`). If
quota bites, drop `node_desired_size` to 1.

### Networking / IAM / Other

- 1 VPC per account (base module creates exactly one).
- 2 NAT GW (one per AZ) — do not add more AZs.
- 5 Elastic IPs default; 2 used by the NAT GW pair.
- IAM users **cannot** be created; IAM roles can. Workflow uses the injected
  `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` (AdministratorAccess scope).
- Route53: **one pre-created public hosted zone** per sandbox; auto-discovered
  by CI into `TF_VAR_domain` / `TF_VAR_route53_zone_id`.
- ACM, Secrets Manager, Cognito, S3, DynamoDB, EKS: all available.
- Not available: Organizations, Control Tower, SSO/Identity Center, WorkSpaces,
  Connect.

### Pre-flight checklist before any apply

- [ ] `node_desired_size` ≤ 2 in `terraform/management/`
- [ ] `node_instance_type` = `t3.medium` or smaller
- [ ] Exactly 2 entries in `availability_zones`
- [ ] No t3.large+, no m/c/r family instances anywhere in the diff

---

## 2. Phase State Model

The project is built up in phases (iterations 0–6, see `ai/handoff.md`). At
any moment during a sandbox session, each phase is in **exactly one** of
these states:

| State | Meaning | Next action |
|---|---|---|
| `not-coded` | No `.tf` / manifest files exist for the phase | Author the code |
| `code-only` | Code exists, never planned in CI this session | `plan` |
| `plan-green` | `terraform plan` (or k8s dry-run) passes; not applied | `apply-and-verify` |
| `applied` | `apply` succeeded; verify not yet run | `verify` |
| `verified` | `apply` + all E2E verify checks passed | (move to phase N+1) |
| `broken` | Last `apply` or `verify` failed; debug loop active | §4 inner loop |

The agent learns the current state from the **Current Sandbox Session** block
at the top of `ai/handoff.md`. That block is the source of truth — if it's
wrong, fix it before doing anything else.

**The state model is per-sandbox-session, not project-wide.** When a new
sandbox starts, all phases reset to (at best) `plan-green` because S3 state
was deleted with the previous account. The cumulative "this phase has *ever*
been verified" lives in the `Iteration progress` table further down in
handoff.md.

---

## 3. The "Work on Phase N" Procedure

When the user says **"work on phase N"** / **"let's do phase N"** /
**"/work-on N"** / equivalent, the agent runs this procedure end-to-end
**without further prompting**.

### Phase 1: orient

1. Read `ai/handoff.md` → Current Sandbox Session block.
2. If sandbox is expired or unknown, ask the user once: "Is the sandbox live?
   What's the start time?" Then update handoff and continue.
3. Build the work plan from the per-phase states.

### Phase 2: cumulative bring-up (phases 0..N-1)

For each phase `K` from 0 to N-1, **in order**:

- `verified` → skip
- `not-coded` → STOP. Should not happen for a prior phase; tell the user.
- anything else → `workflow_dispatch (phase=K, action=apply-and-verify)`,
  watch with `terraform-ci-watch`. On success, mark `verified` in handoff and
  commit. On 3-strike failure, STOP and escalate.

The bring-up runs sequentially because each phase depends on the previous
phase's outputs (base remote state, kubeconfig, etc.).

### Phase 3: phase N itself

Branch on phase N's state:

#### State = `not-coded`

This is the interesting case. The agent does two things in parallel:

- **Background thread (CI):** While phases 0..N-1 are still spinning up in
  GitHub Actions (the slow part — minutes to tens of minutes), the agent does
  not block. It keeps `terraform-ci-watch` polling.
- **Foreground thread (authoring):** The agent reads `ai/REQUIREMENTS.md` (the
  `REQ-*` entries for this phase) and `ai/DESIGN.md` (the relevant ADR and
  architecture sections), then authors the phase-N code on the current
  branch. Files land in the directories listed in CLAUDE.md's File Layout
  Reference.

Once authoring is far enough along to be worth checking:

1. Push and `workflow_dispatch (phase=N, action=plan)`.
2. Iterate on plan errors until plan-green. (Plan does not touch live AWS
   beyond reading state, so this is cheap and safe to run repeatedly even
   while earlier phases are still applying.)
3. **Wait** for phase N-1 to report `verified`.
4. `workflow_dispatch (phase=N, action=apply-and-verify)`.
5. On failure, enter §4 inner debug loop.

#### State = `code-only` or `plan-green`

`workflow_dispatch (phase=N, action=apply-and-verify)` after the bring-up
completes. On failure, §4.

#### State = `applied` or `broken`

`workflow_dispatch (phase=N, action=verify)` first — it's cheap (~2 min, no
Terraform). If verify passes, mark verified. If verify fails, §4.

#### State = `verified`

Tell the user the phase is already verified in this session and ask what they
want next.

### Phase 4: bookkeeping

On every successful state transition:
- Update the **Current Sandbox Session** block in `ai/handoff.md`.
- Commit (`chore(handoff): phase N → verified` or similar).
- Push.

At the end of the working session — **do not run any destroy**. Just update
handoff with what's currently live, commit, and stop. Sandbox expiry will
handle teardown.

---

## 4. Inner Debug Loop (single phase only)

When phase N is `broken`, the agent enters this loop. **Phases 0..N-1 stay
live throughout — never destroy them as part of debugging phase N.**

```
strikes = 0
loop:
    1. Fetch the failure logs (terraform-ci-watch handles this).
    2. Classify with .claude/skills/terraform-ci-watch/reference/failure-taxonomy.md.
    3. Decide the fix:
         - If the fix is a pure tag, count, or non-identity attribute change
           that Terraform can update in place: edit, commit, push, dispatch
           apply-and-verify, watch.
         - If the fix changes an identifying attribute, schema, or recovers
           from state drift: edit, commit, push, dispatch destroy on phase N
           only, then dispatch apply-and-verify, watch.
         - If the failure taxonomy entry says "escalate": go to step 6.
    4. On verify success → exit loop, update handoff, commit. Done.
    5. On failure → strikes += 1; if strikes < 3, return to step 1.
    6. Three strikes → STOP, emit the structured escalation report from
       reference/escalation-template.md, do not push a 4th attempt.
```

### Three invariants

1. **Never destroy a phase below N.** If the apparent fix seems to require
   it, the diagnosis is wrong — re-classify, or escalate.
2. **Never destroy at session end.** Sandbox expiry is the cleanup mechanism.
3. **Re-running `verify` is free.** Prefer it over re-applying when the
   underlying failure was timing-related (DNS propagation, slow image pull,
   IRSA propagation).

---

## 5. Session Budget Arithmetic

Approximate wall-clock per action (revise as data comes in):

| Action | Duration |
|---|---|
| `plan` (either phase) | 1–2 min |
| `apply-and-verify` base | ~3 min |
| `apply-and-verify` management | ~15 min |
| `verify` only (no Terraform) | ~2 min |
| `destroy` management | ~10 min |
| `destroy` base | ~3 min |

### Worked example: first-ever phase 1 bring-up + debugging

```
0:00  start sandbox, rotate 3 GitHub secrets
0:00  apply-and-verify base                              ( 3 min)
0:03  apply-and-verify management                        (15 min)
0:18  → failed verify (ArgoCD URL DNS not propagated)
0:18  verify management (retry, no terraform)            ( 2 min)
0:20  → still failing; classify → ExternalDNS issue → tf fix
0:25  push fix, destroy management, apply-and-verify     (10 + 15 = 25 min)
0:50  → green
0:50  update handoff, commit, push
3:00  …time spent on phase 2 code authoring…
4:00  sandbox expires; no destroy needed
```

Heuristic: each phase-1 debug iteration costs ~25 minutes (destroy + apply +
verify). With a 4-hour budget and ~20 min already spent on the first
bring-up, **expect ~7 debug iterations max per session**. If you're not
green by the 5th, stop and think rather than burn the remaining budget.

---

## 6. Workflow Actions Reference

`.github/workflows/terraform-test.yml` exposes two inputs on
`workflow_dispatch`:

- `phase`: `base` | `management` | `test`
- `action`: `plan` | `apply` | `verify` | `apply-and-verify` | `destroy` | `test-unit` | `test-e2e`

`test-unit` and `test-e2e` are only valid when `phase=test`; the other
five actions are only valid for `base` and `management`. The Agent
Trigger workflow (§8) and `compute-gates.sh` enforce this.

| `phase` × `action` | What runs |
|---|---|
| `base, plan` | `[base] init` + `[base] plan` |
| `base, apply` | above + `[base] apply` |
| `base, verify` | `[base] init` + `[base] e2e-verify` (no terraform changes) |
| `base, apply-and-verify` | apply then verify in one run |
| `base, destroy` | `[base] init` + `[base] destroy` |
| `management, plan` | `[mgmt] init` + `[mgmt] plan` |
| `management, apply` | above + `[mgmt] apply` |
| `management, verify` | mgmt init + `[mgmt] e2e-verify` + `[mgmt] argocd-url` |
| `management, apply-and-verify` | apply then verify in one run |
| `management, destroy` | `[mgmt] init` + `[mgmt] destroy` |
| `test, test-unit` | `tests/unit/run.sh` (no AWS, no Terraform) |
| `test, test-e2e` | `tests/e2e/run.sh` (read-only AWS assertions) |

Push to `test/**` keeps the old behaviour: plan both phases on every push
(no apply, no destroy). It does not exercise the `phase=test` path —
that is dispatch-only or agent-trigger-only.

---

## 7. What to Update After Each Step

After a state-changing run completes, the agent updates these fields in
`ai/handoff.md` → Current Sandbox Session block:

- `Phase states` table: state column for the phase in question
- `Phase states` table: Last action column with timestamp and brief result
- `Phase states` table: Run URL column (the GitHub Actions run that produced
  the new state)

If the phase reached `verified` for the first time *ever* (not just this
session), also bump the `Iteration progress` table further down in
handoff.md.

Commit with `chore(handoff): phase N → <new-state>`.

---

## 8. Agent-Triggered Runs (`.trigger-action.json`)

Claude Code on the web has no `workflow_dispatch` primitive — no `gh` CLI,
no direct GitHub API, and the available MCP toolset omits dispatch. To let
the agent drive the phase procedure end-to-end without a human in the
Actions UI, the repo provides a **commit-based trigger**: when the file
`.trigger-action.json` changes on a non-default branch, the
`Agent Trigger` workflow parses it and calls `terraform-test.yml` with the
parsed `phase` and `action`.

### File schema

```json
{
  "phase":  "base | management | test",
  "action": "<see below>",
  "nonce":  "<arbitrary string>"
}
```

Action is tuple-validated against phase:

- `phase ∈ {base, management}` → `action ∈ {plan, apply, verify, apply-and-verify, destroy}`
- `phase = test` → `action ∈ {test-unit, test-e2e}`

- `phase` and `action` are validated by the trigger workflow; invalid
  values fail fast with `::error` annotations in the Actions log.
- `nonce` is informational only — its purpose is to let the agent
  re-fire the same `phase + action` combination by changing the nonce.
  Without it, an identical JSON body would be a no-op commit and CI
  would not re-run.

A canonical example lives at `.trigger-action.json.example`.

### Agent flow

1. Decide the next `phase × action` per §3.
2. Write `.trigger-action.json` with that decision and a fresh nonce
   (timestamp works well).
3. Commit (`ci: fire <phase> <action>`) and push.
4. Use the `terraform-ci-watch` skill to poll the resulting run.
5. After the run completes, update `ai/handoff.md` per §7.

### Safety properties

- **Audit trail.** Every CI fire is a git commit. The PR diff shows
  exactly what the agent intended.
- **Default-branch guard.** The trigger workflow skips when
  `github.ref == refs/heads/<default>`, so merging a PR that contains
  a stale `.trigger-action.json` will not accidentally re-apply
  Terraform.
- **Concurrency.** The Agent Trigger and Terraform Test workflows both
  set `concurrency:` groups keyed on `github.ref`, so a new fire on
  the same branch cancels an in-flight one.
- **Validation.** Malformed JSON, missing fields, or values outside the
  allowed enums fail the trigger job before any Terraform code runs.

### What this does *not* change

- `workflow_dispatch` on `terraform-test.yml` still works for humans.
- The `test/**` push trigger still runs plan-only on both modules.
- The phase × action gate logic in `terraform-test.yml` is the single
  source of truth for what each action actually does (§6).

---

## 9. Testing the Harness (`phase = test`)

The trigger mechanism (§8), the gate logic (§6), and the helper
scripts under `.github/scripts/` are themselves software, and they
fail in interesting ways: a regex typo in `parse-trigger.sh` could
silently let `phase=destroy_everything` through; a bad case in
`compute-gates.sh` could fire `mgmt_destroy` when the agent asked
for `mgmt_plan`. Those failures are catastrophic *for the procedure*
even when the underlying Terraform code is fine.

The `phase=test` pair exists so these components have automated
coverage independent of the AWS-touching paths.

### Two actions

| `action` | What runs | AWS needed? | Typical duration |
|---|---|---|---|
| `test-unit` | `tests/unit/run.sh` — exercises `parse-trigger.sh` and `compute-gates.sh` against `tests/unit/fixtures/*.json` | No | <10 s |
| `test-e2e`  | `tests/e2e/run.sh` — read-only assertions against the live sandbox (sts:GetCallerIdentity, Route53, S3 bucket, DynamoDB table) | Yes | <30 s |

### When to run them

- **Every PR that touches `.github/scripts/`, `.github/workflows/`,
  `tests/`, or `.trigger-action.json.example`** should fire
  `phase=test, action=test-unit` at least once and confirm it passes.
- **Every fresh sandbox session** should fire `phase=test, action=test-e2e`
  once after the first `apply-and-verify` on phase 0 — it's the cheapest
  way to confirm bootstrap actually produced the expected side effects
  (state bucket + lock table + Cognito test creds).
- The unit suite is also run locally with `tests/unit/run.sh` — no env
  required.

### Adding coverage

The fixture-driven shape (`tests/unit/fixtures/*.json` for parse tests;
`(event, phase, action)` tuples for gate tests) keeps each test cheap
to add. When you discover a class of misconfiguration that slipped
through review, add a fixture and a test before the fix.

### Limits

- `phase=test` does **not** test the Terraform pipeline itself. The
  existing `[base] e2e-verify` and `[management] e2e-verify` steps
  remain the contract assertions for the Terraform actions; they run
  as part of `verify` / `apply-and-verify` on the real phases.
- The harness tests assume `jq`, `bash`, and (for e2e) `aws` CLI are
  on PATH. The GitHub-hosted runner provides all three; local
  contributors must install them.
