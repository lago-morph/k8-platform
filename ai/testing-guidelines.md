# Testing Guidelines — k8-platform

This document describes (a) the AWS account constraints the project operates
under, (b) the **phase-by-phase development workflow** the agent is expected
to follow, and (c) the inner debug loop used to drive a single phase to
"verified" state.

The agent reads this file whenever the user says "work on phase N" or any
equivalent phrasing. `CLAUDE.md` points here.

---

## 1. AWS Account Constraints

The target AWS account has the following limits and pre-existing resources.
Adjust the pre-flight checklist if your account differs.

### EC2

| Constraint | Value |
|---|---|
| Allowed families/sizes | t2 / t3 / t3a / t4g — only `micro`, `small`, `medium` |
| Max EBS volume | 100 GB per volume |
| Max concurrent instances | **9** total across all services |

Management cluster default: `t3.medium × 2` (`desired=2, min=1, max=3`). If
quota bites, drop `node_desired_size` to 1.

### Networking / IAM / Other

- 1 VPC per account (base module creates exactly one).
- 2 NAT GW (one per AZ) — do not add more AZs.
- 5 Elastic IPs default; 2 used by the NAT GW pair.
- IAM users **cannot** be created; IAM roles can. Workflow uses the injected
  `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` (AdministratorAccess scope).
- Route53: **one pre-existing public hosted zone**; auto-discovered by CI
  into `TF_VAR_domain` / `TF_VAR_route53_zone_id`.
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
any moment, each phase is in **exactly one** of these states:

| State | Meaning | Next action |
|---|---|---|
| `not-coded` | No `.tf` / manifest files exist for the phase | Author the code |
| `code-only` | Code exists, never planned in CI | `plan` |
| `plan-green` | `terraform plan` (or k8s dry-run) passes; not applied | `apply-and-verify` |
| `applied` | `apply` succeeded; verify not yet run | `verify` |
| `verified` | `apply` + all E2E verify checks passed | (move to phase N+1) |
| `broken` | Last `apply` or `verify` failed; debug loop active | §4 inner loop |

The agent learns the current state from the **Environment State** block at
the top of `ai/handoff.md`. That block is the source of truth — if it's
wrong, fix it before doing anything else.

State transitions persist across sessions because Terraform state lives in
S3 and the cluster keeps running. The `Iteration progress` table further
down in handoff.md records the longer-term "this phase has been verified at
least once" view.

---

## 3. The "Work on Phase N" Procedure

When the user says **"work on phase N"** / **"let's do phase N"** /
**"/work-on N"** / equivalent, the agent runs this procedure end-to-end
**without further prompting**.

**Dispatch mechanism.** Every reference to `workflow_dispatch (...)` below
resolves to a DISPATCH operation under the active capability profile —
`gh` CLI, GitHub MCP server with Actions coverage, or `ext-github` via
jentic, in that preference order. Detection and the per-profile
implementation of DISPATCH (and the read operations used in polling and
log fetching) live in
`.claude/skills/terraform-ci-watch/reference/capabilities.md`. The
`terraform-ci-watch` skill performs detection once per invocation and
owns the polling loop and the 3-strike escalation envelope. If the active
profile fails for connectivity reasons mid-loop, the skill re-detects per
`capabilities.md` §3; if degradation lands on `ext-github` and jentic
itself is unreachable, see §9 below for the handoff fallback.

### Phase 1: orient

1. Read `ai/handoff.md` → Environment State block.
2. If state is stale or contradicts a recent CI run, refresh it before
   doing anything else.
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

Tell the user the phase is already verified and ask what they want next.

### Phase 4: bookkeeping

On every successful state transition:
- Update the **Environment State** block in `ai/handoff.md`.
- Commit (`chore(handoff): phase N → verified` or similar).
- Push.

When wrapping up: do not run `destroy` unless that is itself the work
being done. The environment persists; leaving phases live is the expected
state between sessions.

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

### Two invariants

1. **Never destroy a phase below N.** If the apparent fix seems to require
   it, the diagnosis is wrong — re-classify, or escalate.
2. **Re-running `verify` is free.** Prefer it over re-applying when the
   underlying failure was timing-related (DNS propagation, slow image pull,
   IRSA propagation).

### IRSA invariant

- Run `scripts/irsa_trust_validator.py --all --ci` after every
  `terraform apply` that touches `terraform/management/irsa.tf` or any
  `DeploymentRuntimeConfig`. A non-zero exit means a new Bug 5
  (IRSA SA-name drift). See SPEC-S3.

---

## 5. Action Wall-Clock Reference

Approximate per-action duration. Use to estimate how long a sequence of
dispatches will take and decide whether to do something else in parallel.

| Action | Duration |
|---|---|
| `plan` (either phase) | 1–2 min |
| `apply-and-verify` base | ~3 min |
| `apply-and-verify` management | ~15 min |
| `verify` only (no Terraform) | ~2 min |
| `destroy` management | ~10 min |
| `destroy` base | ~3 min |

Each inner-loop debug iteration on phase 1 costs ~25 minutes (destroy +
apply + verify). If you haven't reached green by the 5th iteration, stop
and rethink the diagnosis rather than keep cycling.

---

## 6. Workflow Actions Reference

`.github/workflows/terraform-test.yml` exposes two inputs on
`workflow_dispatch`:

- `phase`: `base` | `management` | `test`
- `action`: `plan` | `apply` | `verify` | `apply-and-verify` | `destroy` | `test-unit` | `test-e2e`

`test-unit` and `test-e2e` are only valid when `phase=test`; the other
five actions are only valid for `base` and `management`.
`compute-gates.sh` enforces this.

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

Every action is dispatched via `workflow_dispatch` — there are no
auto-triggers on `terraform-test.yml`.

---

## 7. What to Update After Each Step

After a state-changing run completes, the agent updates these fields in
`ai/handoff.md` → Environment State block:

- `Phase states` table: state column for the phase in question
- `Phase states` table: Last action column with timestamp and brief result
- `Phase states` table: Run URL column (the GitHub Actions run that produced
  the new state)

If the phase reached `verified` for the first time, also bump the
`Iteration progress` table further down in handoff.md.

Commit with `chore(handoff): phase N → <new-state>`.

---

## 8. Testing the Harness (`phase = test`)

The gate logic (§6) and the helper scripts under `.github/scripts/`
are themselves software, and they fail in interesting ways: a bad
case in `compute-gates.sh` could fire `mgmt_destroy` when the agent
asked for `mgmt_plan`. Those failures are catastrophic *for the
procedure* even when the underlying Terraform code is fine.

The `phase=test` pair exists so these components have automated
coverage independent of the AWS-touching paths.

### Two actions

| `action` | What runs | AWS needed? | Typical duration |
|---|---|---|---|
| `test-unit` | `tests/unit/run.sh` — exercises `compute-gates.sh` against `(phase, action)` tuples | No | <10 s |
| `test-e2e`  | `tests/e2e/run.sh` — read-only assertions against the live account (sts:GetCallerIdentity, Route53, S3 bucket, DynamoDB table) | Yes | <30 s |

### When to run them

- **Every PR that touches `.github/scripts/`, `.github/workflows/`,
  or `tests/`** should fire `phase=test, action=test-unit` at least
  once and confirm it passes.
- **After each fresh `apply-and-verify` of phase 0**, fire
  `phase=test, action=test-e2e` once — it's the cheapest way to confirm
  bootstrap produced the expected side effects (state bucket + lock
  table + Cognito test creds).
- The unit suite is also run locally with `tests/unit/run.sh` — no env
  required.

### Adding coverage

The fixture-driven shape (`(phase, action)` tuples for gate tests)
keeps each test cheap to add. When you discover a class of
misconfiguration that slipped through review, add a fixture and a
test before the fix.

### Limits

- `phase=test` does **not** test the Terraform pipeline itself. The
  existing `[base] e2e-verify` and `[management] e2e-verify` steps
  remain the contract assertions for the Terraform actions; they run
  as part of `verify` / `apply-and-verify` on the real phases.
- The harness tests assume `jq`, `bash`, and (for e2e) `aws` CLI are
  on PATH. The GitHub-hosted runner provides all three; local
  contributors must install them.

### Unit-test inventory

| Test file | What it covers | Fixtures |
|---|---|---|
| `test_compute_gates.sh` | `compute-gates.sh` (phase × action gate matrix) | `tests/unit/fixtures/compute-gates/` |
| `test_whereami.sh` | `scripts/whereami.sh` JSON schema, human fields, credential-absent exit, partial-kubectl exit 0, `--cache` file vars, fixture field match. Adversarial additions: null-value guard, `--help` exit 0, lib direct-exec guard. | `tests/unit/fixtures/whereami/` |

For any new e2e or integration test, confirm the first step invokes
`scripts/whereami.sh --json` as a precondition gate (SPEC-S4 §5).

---

## 9. Last-Profile Outage — Handoff Fallback

The agent reaches GitHub's Actions API via one of three capability
profiles, in preference order: `gh` CLI, GitHub MCP server with Actions
coverage, then `ext-github` via jentic
(`.claude/skills/ext-github/`). Detection and the per-profile dispatch
table live in
`.claude/skills/terraform-ci-watch/reference/capabilities.md`. In many
environments (including the current Claude Code on the Web configuration)
only `ext-github` is available, so it functions as both first and last
resort.

When a call on the **active** profile fails for connectivity reasons —
e.g. jentic 5xx, jentic rate-limited or unreachable, the upstream PAT
expired/got revoked, the MCP server returns "tool unavailable",
`gh` authentication lapsed — the agent re-runs detection per
`capabilities.md` §3. If detection produces a different profile, retry
the same operation on it. If detection produces "none" — every profile
has failed — fall back to the handoff path:

Write the intended next action — `workflow_id`, `ref`, full `inputs`
map, and the reason for falling back — into the Environment State
block at the top of `ai/handoff.md`, commit, and stop. A human resumes
by dispatching the recorded action manually via the GitHub Actions UI
(Actions → terraform-test → "Run workflow") and updates handoff with
the resulting run URL. The session does not attempt to recover
automatically; all-profile outages are rare and the manual path is
fast.

The `ext-github` skill itself is one-shot per call (no in-skill retries
— see `ai/specs/ext-github-design.md` §4); the re-detection-and-retry
above happens at the `terraform-ci-watch` outer layer, not inside any
individual profile.
