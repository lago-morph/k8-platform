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

### 6.4 Chainsaw scenario authoring conventions

Every chainsaw scenario MUST inherit the canonical `catch:` block from
`tests/chainsaw/_lib/catch-block.yaml`. The block runs on any step
failure and emits the XR `describe`, every referenced MR's `describe`,
and recent reconcile events for the test namespace — inline in the
chainsaw log.

Authoring a new scenario:

1. Paste the contents of `tests/chainsaw/_lib/catch-block.yaml` into
   the scenario's `Test.spec.catch:` list verbatim.
2. Edit only the first `describe.kind` line to match the XR your
   scenario owns (`PlatformSecret`, `PlatformCluster`, etc.). Every
   other field is structurally enforced.
3. Run `bash tests/unit/test_chainsaw_catch_block.sh` locally — it
   asserts the block is present and structurally matches the
   canonical fragment.

The unit test runs in `.github/workflows/unit-tests.yml` on every push,
so a missing or drifted block fails CI before the chainsaw harness
runs. The meta-test `tests/chainsaw/meta-catch-fires/` is the live
proof that the catch block fires; `tests/chainsaw/run.sh` inverts the
exit-code expectation for any scenario whose name begins with `meta-`.

When the adversarial-review step (AGENTS.md §6.4) runs for a new
chainsaw scenario, confirm the shared `catch:` block is present and
the `kind` override is correct.

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

### Composition render fixtures (SPEC-S9)

Every Composition in `crossplane/compositions/` MUST have a
`render-fixtures/` directory under its XRD subdirectory
(`crossplane/xrds/<name>/render-fixtures/`) containing `input.yaml`
(the probe claim, with a pinned `metadata.uid`) and `expected.yaml`
(the golden rendered output). Use `scripts/composition-render.sh` to
bootstrap and verify. The `tests/unit/test_composition_render_fixtures.sh`
unit test enforces presence; the pre-commit hook fires on every
Composition or fixture edit. See SPEC-S9 in
`ai/brainstorming/specs/SPEC-S9-composition-render-dryrun.md`.

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

### The kubeconform schema store (`kubeconform-schemas/`)

Static schema validation runs as
`tests/unit/test_kubeconform_manifests.sh` (SPEC-S6) and scans every
YAML under `crossplane/`, `argocd/`, `clusters/`, `policies/` on every
push. It catches the silent-schema-mismatch bug class — fields rejected
at admission time but accepted by `kubectl apply` — at commit time.

The lint reads schemas from `kubeconform-schemas/`, a committed JSON
schema store. CI runners cannot reach the EKS cluster, so the schemas
are pre-fetched locally and checked in. Regenerate with:

```bash
bash scripts/fetch-crds-for-kubeconform.sh
```

The script auto-detects a live cluster (preferred) and falls back to
fetching pinned upstream CRD YAMLs when no cluster is reachable. It
also extracts `platform.k8-platform.io` schemas from the repo's own
XRDs and the `pt.fn.crossplane.io` function-input schema from the
`function-patch-and-transform` OCI package (SPEC-S6 §5.3).

**Regenerate after** bumping any Crossplane / Kyverno / ESO / ArgoCD /
provider-aws version pin in `tests/chainsaw/versions.env` or
`terraform/management/variables.tf`, after adding or modifying an XRD,
or after adding a new CRD group used by a new repo manifest. Commit
the diff in the same PR.

**Allowlist syntax.** A YAML file may opt out by carrying
`# kubeconform-skip` in its first 5 lines. The fallback exists for
documentation placeholders (e.g. `subnet-REPLACE-ME-AZ*` in example
claims); the bias is **fix the manifest, not add a skip**. Every skip
must be accompanied by a comment naming the load-bearing reason — see
`kubeconform-schemas/README.md` for the current allowlist + rationales.

### Integration-test wait conventions (SPEC-S7)

Claim waits inside `tests/integration/NN_*.sh` and chainsaw `try.script`
blocks **must** call `scripts/wait-for-claim.sh <kind> <name> [ns] [timeout]`
rather than a bespoke `until kubectl get ... | grep True` loop. The
script exits 1 on timeout and auto-dumps the last-seen `.status.conditions`,
composition events, and recent cluster events to stdout — eliminating
the need for per-test dump logic and defending against the
PR #59 (silent-PASS, missing `-e`) and PR #67 (empty-status false-positive)
bug classes. See `ai/brainstorming/specs/SPEC-S7-wait-for-claim.md`.

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

---

## 10. Diagnosing failing CI checks

**Read the failure log before forming any hypothesis.** When any
GitHub Actions check on a PR fails, the FIRST action is to fetch the
job log. Do not read the PR description, the workflow YAML, the spec,
the test source, or the commit message before reading the log. The log
contains the actual error in chainsaw / kubectl / terraform / pytest
output; everything else is a guess about what the log might say.

Procedure:

1. Identify the failed job ID from the check's `details_url` (the last
   path segment is the job ID, e.g.
   `…/actions/runs/26418951701/job/77769403164` → job ID `77769403164`).
2. Fetch the log via the `ext-github` skill's `download_job_logs`
   operation (`op_c08d23e5bd6966cb`), passing `owner`, `repo`, and
   `job_id`.
3. Logs are large (~100k–200k chars). Save to a file and grep / tail
   for the actual error message — usually near the bottom of the log,
   after a `FAIL:` or `Error:` or `##[error]` marker.
4. Quote the relevant log lines verbatim in any commit message, retro
   entry, or PR comment describing the fix. This keeps the diagnosis
   auditable and prevents the next session from re-guessing.

**Why this matters.** The autonomous run on 2026-05-25 spent multiple
turns speculating about PR #91's chainsaw failure ("workflow doesn't
honor `tests/chainsaw/run.sh`", "meta-test exit-code inversion broken")
based on the workflow YAML and the spec. None of the hypotheses
matched what actually happened. The real cause was a marker-string
mismatch in `tests/chainsaw/run.sh`'s post-test grep — a single
`grep -q` line — visible immediately in the chainsaw stdout but
invisible from any other source. The whole speculative arc was
wasted effort directly addressable by reading the log first.

This rule applies to terraform-test, chainsaw, unit-tests,
chainsaw-verify, integration-tests, phase-2-diagnose — any failing
GitHub Actions check.

### 10.1 Verify environmental preconditions before debugging code

Before chasing a "code" hypothesis on a CI failure, check that the
environmental preconditions still hold:

- **AWS credentials.** Per §8.1, the test account is rotated between
  sessions. If a CI run shows
  `InvalidClientTokenId` / `The security token included in the request is invalid` /
  `403 Forbidden` from STS or any AWS API, the in-repo credentials
  are stale — the code is fine. Re-rotate credentials before any code
  change. Symptom in chainsaw: every real-AWS scenario fails with
  `CannotConnectToProvider`. Workaround for the autonomous-run window:
  dispatch chainsaw with `scenario_filter: _smoke` so the harness
  validates itself without requiring AWS.
- **Cluster reachability.** If `kubectl` returns
  `connection refused` / `dial tcp: lookup ...: no such host`, the
  cluster has been torn down or the kubeconfig is stale. See §8.1.
- **Tool availability.** A missing CLI (helm, kubeconform,
  crossplane) is environmental, not code. The unit test should
  skip-with-warning, not fail.

If the failure cause is environmental, document it in the PR body
and stop debugging code. A code fix on top of an environmental
failure ships the wrong fix.

---

## 11. CI and Agent Operating Rules

### 11.1 Live-admission verification for v2 Crossplane CRD changes

**Dispatch live chainsaw before relying on kubeconform alone for v2
Crossplane manifest changes.** For any PR that migrates Crossplane
manifests across a major API-version boundary (e.g. v1 → v2 group
rename, XRD `apiextensions/v1` → `/v2`, Composition rewrites with new
`providerConfigRef` shapes), dispatch `chainsaw.yml` against the branch
SHA and confirm at least the `xrd-establishes` scenario passes BEFORE
merging.

**Why kubeconform isn't sufficient here.** The static kubeconform JSON
schema is generated from the CRD's `openAPIV3Schema`. The live admission
webhook has additional handler logic that can reject fields the schema
accepts — for example, `compositeresourcedefinition_v2.json` accepts
`connectionSecretKeys` on a v2 XRD (the field still exists in the v2 CRD
for back-compat), but the v2 admission webhook rejects it at apply time.
See `docs/decisions/0001-kubeconform-not-sole-gate-for-v2-crd-changes.md`
for the full ADR.

**Operating contract** (specializes AGENTS.md §6.7):

1. After kubeconform CI is green, dispatch `chainsaw.yml` against
   `BRANCH` with `commit_sha=$(git rev-parse HEAD)`. Use
   `scenario_filter=""` for full set, or at minimum a filter that
   includes `xrd-establishes`.
2. On failure: fetch the chainsaw stdout via `ext-github`
   `op_c08d23e5bd6966cb` per §10 BEFORE forming hypotheses. Common v2
   admission-rejection shapes: `is invalid: spec: Invalid value: …`,
   `--for=condition=Offered` timeouts (v2 has no claim CRD, so the
   Offered condition never appears), `no matches for kind <V1Kind>`.
3. On success: paste the chainsaw run URL into the PR description
   under "§6.7 chainsaw contract".
4. Only then consider the PR ready to merge.

**Schema-pass IS still the necessary first gate** — kubeconform catches
field-structure changes that the schema correctly reflects. This rule
supplements it with a live-admission gate for the specific class of
failures the schema can't express.

### 11.2 Read the failure log first

**When ANY CI check fails, the first action is to fetch the job log.**
Do not read the PR description, workflow YAML, spec, test source, or
commit message before reading the log. Hypotheses formed from indirect
sources are guesses; the actual error is in the workflow stdout.

See §10 for the full procedure including §10.1 on verifying environmental
preconditions before debugging code.

### 11.3 Never foreground-poll a long-running CI run

Every tool call re-uploads the accumulated conversation context. A 100K-token
session that foreground-polls a 15-minute CI run every 10 seconds spends
~9 million input tokens learning `status: in_progress` repeatedly.

**The rule.** When waiting for any GitHub Actions workflow that takes >1 minute:

1. **Dispatch exactly ONE background poll** via `Bash` with
   `run_in_background: true`. The poll loop exits only when
   `status=completed`:
   ```bash
   until [ "$(curl -sS "https://api.github.com/repos/$OWNER/$REPO/actions/runs/$RUN_ID" \
       | python3 -c "import json,sys; print(json.load(sys.stdin).get('status',''))")" = "completed" ]; do
     sleep 60
   done
   ```
2. **Make no tool calls querying that run's status** until the background
   poll's completion notification arrives. No periodic status checks.
3. **One background poll per run.**
4. **Do parallel-author work in the meantime** on anything that doesn't
   depend on the running CI.

**Sandbox suspend / resume.** When the sandbox suspends mid-wait, webhooks
that arrive during suspension do not deliver on resume. When you resume
after an idle period, OR when no webhook event has arrived by **expected
ETA + 50%**, issue ONE direct API query against the run id. ONE. If that
returns `in_progress`, dispatch a new background poll rather than polling
manually. Do not begin polling on a regular interval.

### 11.4 `[Request interrupted by user]` is a hard stop

When the harness delivers `[Request interrupted by user]`, do NOT pivot
into an adjacent task. Stop the current activity, do not start a new one,
and wait for the user's next explicit direction. Background processes the
agent had started prior to the interrupt should be killed if they continue
to consume model context or registry/API quota.

### 11.5 Don't claim a tool is "unavailable" until you've tried to install or start it

Before reporting "X is not available in this sandbox", attempt the obvious
installation or activation paths:

1. **Already installed but not on PATH?** `which X`, `ls /usr/bin/X /usr/local/bin/X /root/.local/bin/X`
2. **Daemon installed but stopped?** `systemctl status X`, `pgrep X`, `sudo Xd &`
3. **One-line install available?** `curl -fL <release-url> -o /tmp/X && chmod +x /tmp/X`

Report "unavailable" only after at least one of those attempts fails with a
concrete error.

### 11.6 Run a pre-dispatch static audit before any long CI dispatch

**Before dispatching a long-running CI workflow** (chainsaw, terraform-test,
integration suite), run `scripts/pre-chainsaw-audit.sh`. The audit MUST
cover at minimum:

- (a) Non-ASCII characters in tag-bound `description:` / `Description:` fields (the AWS Resource Groups Tagging service rejects them).
- (b) `set -o pipefail` / `[[ ]]` / other bash-isms in chainsaw `script.content:` blocks (chainsaw runs scripts under `/bin/sh`).
- (c) `status.conditions:` array length not equal to 3 on v2 XR asserts (v2 carries Synced + Ready + Responsive).
- (d) `($namespace)` literals in `apply.resource.metadata.namespace` (chainsaw's pre-substitution validation rejects these as invalid RFC 1123 labels).
- (e) Golden YAMLs missing `metadata.namespace: default` (chainsaw `assert: file:` searches the per-test namespace by default).
- (f) Golden-vs-scenario data-value drift on fields the Composition propagates (notably `tags.Description`).

Each check is a one-line grep; the full audit runs in seconds. Fix every
FAIL before dispatching; re-run until clean.

### 11.7 Use Bash `run_in_background`, not Monitor, for single-notification waits

Use `Bash` with `run_in_background: true` and an `until <check>; do sleep <N>; done`
loop for "tell me when X completes." Reserve `Monitor` for streams of
multiple events. A Monitor that just sleeps and ticks is an anti-pattern —
every tick is a chat-visible notification, the monitor doesn't end on the
event you care about, and there is no surfaced way to stop it early.

### 11.8 Webhook backup poll at 1.5x expected ETA

When a webhook subscription is the agreed completion channel and 1.5x the
expected ETA has elapsed with no event, do a single direct-API status query.
PR-activity subscriptions occasionally drop `workflow_run completed` events
without dropping surrounding `check_suite` failure events; silence on the
channel does not mean the work is still running. Confirm with one direct-API
call before assuming. One direct call at ETA + 50% does not constitute a
polling loop — it's a single fallback query.

### 11.9 `tests/unit/run.sh` and `.github/workflows/unit-tests.yml` must stay in sync

Every test in `tests/unit/run.sh` MUST also be enumerated in
`.github/workflows/unit-tests.yml`'s per-step list, OR the workflow must end
with a `run.sh` catch-all step that invokes it. Per-step CI is preferred for
separate-failure diagnosability in the Actions UI; the catch-all trades that
UI clarity for guaranteed coverage. Either pattern is acceptable; the gap
between them is not. When authoring a new `tests/unit/test_*.sh`, the same
PR must update `unit-tests.yml` or rely on the catch-all if it exists.

### 11.10 Never present a hypothesis as a conclusion

State the strength of every claim:

- **Observation** — something seen in logs / output. Quote it.
- **Exclusion** — something ruled out by topology, evidence, or direct test. Name the exclusion criterion.
- **Hypothesis** — a candidate explanation that fits the evidence but is NOT confirmed. Label it as such.
- **Conclusion** — a hypothesis positively tested or following from exhaustive exclusion of every other plausible alternative.

Writing "X is the cause" or "this is not a regression I introduced" claims a
conclusion. That requires positive evidence or exhaustive exclusion. One
fits-the-pattern data point is "consistent with hypothesis X" — not "X is
the cause." The cost of accurate framing is one extra word; the cost of
inaccurate framing is the user's trust.

### 11.11 Never ignore an undiagnosed failure — log to the open-issues register

Every observed failure must either be diagnosed in this session or recorded
in `docs/open-issues.md`. No silent-skip, no "out of scope so I'll move on,"
no leaving a flaky red check unfollowed.

Options:
1. **Diagnose it now.** Fix the issue, write the regression-catching test per
   AGENTS.md §6.2, close the loop.
2. **Defer to a tracked issue.** Add an entry to `docs/open-issues.md` with:
   status, symptom (with verbatim error text), diagnostic evidence, hypotheses
   (labelled per §11.10), what's ruled out, the next concrete diagnostic step,
   and an owner.

Out-of-scope is a valid reason to defer; it is NOT a valid reason to drop the
observation. Pure flakes get an entry too — a flake is "undiagnosed but
observed," not "no problem." Keep closed items removed or in a historical
section; stale entries are a tax on every future agent.

### 11.12 Never silence cleanup failures with `|| true`

Test and CI cleanup steps that depend on succeeding (re-applying state,
deleting resources, restoring config) MUST fail loudly. The `|| true` idiom
masks the underlying error and lets contamination propagate to subsequent
scenarios. If a cleanup is genuinely best-effort, guard with
`[ -f X ] && cmd` or an explicit `if ! cmd; then echo WARN; fi` so the
warning surfaces.

### 11.13 After session resume from suspension, verify status of in-flight dispatches

When the sandbox suspends mid-wait, webhooks that arrive during suspension do
not deliver on resume. The first action after resume — before authoring new
work, before answering a user question that depends on the run's outcome —
is one direct-API query against any in-flight dispatch's run id. This
complements §11.3 (active-wait) and §11.8 (ETA backup): those cover
different triggers; this one covers the resumed-after-suspension case.
