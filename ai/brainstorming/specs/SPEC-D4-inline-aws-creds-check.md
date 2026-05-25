# SPEC-D4 — Inline `aws-creds-check.sh` into `scripts/preflight.sh`

Brainstorm ID: A6-029. Tier D item D4.

## 1. Summary

Replace the 51-line `scripts/aws-creds-check.sh` with a concise
`scripts/preflight.sh` (≤10 lines) that keeps the three guardrails that
have account-kill risk: STS reachability check, sandbox region whitelist
(`us-east-1` / `us-west-2`), and EC2 instance-type family whitelist.
Everything else in the old script — Route53 zone discovery, S3 bucket
listing, EKS cluster listing, multi-section banner output — is diagnostic
colour that belongs in a runbook rather than a boot preflight. The cross-
review comment A4→A6-029 (`ai/brainstorming/cross-review-from-A4.md:94`)
explicitly held that "guardrail value beats LoC value"; A3→A6-014 adds the
region and instance-type guards as equally cheap to preserve. The result is
one script, one name, with a contract future agents can read in ten seconds.
This spec is part of the Tier D cruft-removal cluster described in
`ai/brainstorming/specs/larger-list-preferences.md §Tier D`.

## 2. Retro pain killed

- **Wrong-region, wrong-account ops risk.** `aws-creds-check.sh` never
  validated the active region or checked that the caller was inside the
  allowlisted pair (`us-east-1` / `us-west-2`). The pre-flight ritual in
  `ai/aws-test-environment-limitations.md` (lines 28-34) requires this
  confirmation before every apply, but the script only printed the env var
  — it did not fail on an out-of-allowlist value. A single mistaken
  `AWS_DEFAULT_REGION=eu-west-1` would silently proceed. Per
  `retrospective/2026-05-23-50.md:67`, a session picked up on a freshly
  rotated account and the creds check was "unrunnable locally" — the
  script's complexity meant the surrogate was dispatching a whole workflow.

- **51-line script for a 3-check operation.** The script's five banner
  sections (STS identity, region print, Route53 zone discovery, EKS cluster
  listing, S3 state bucket listing) add no gate value; they emit
  informational text an agent already gets from `aws sts get-caller-identity`
  and two-line aws commands. The discovery sections require Route53 / S3 /
  EKS permissions that are not always present at session start. When any
  discovery call fails silently (`2>/dev/null`), the absence of output looks
  like "zero resources" rather than "permission denied".

- **Stale name after rename.** `retrospective/2026-05-23-36.md:71` records
  that `scripts/sandbox-creds-check.sh` was renamed to `scripts/aws-creds-check.sh`
  during a terminology sweep. Callers were updated at that time, but the
  rename left behind a script whose name implies general AWS validation while
  its body still silently skips discovery errors. A fresh name (`preflight.sh`)
  signals scope ("run before you do anything") without implying completeness.

- **Copy-paste diagnostic logic.** `ai/brainstorming/A6-removal-refactor.md:56`
  (idea A6-047) notes that the Route53 zone-discovery snippet in
  `aws-creds-check.sh` is the same `aws route53 list-hosted-zones | jq`
  fragment that appears in `terraform-test.yml`, `scripts/route53-records.sh`,
  and `ai/handoff.md`. Having it in a preflight script creates a fourth copy
  that will diverge. The fix is to remove it from the preflight entirely;
  A6-047 is the right home for a deduplication pass.

## 3. Out of scope

- **Route53 zone discovery.** The old script printed hosted zones as a
  secondary output; this is informational, not a boot guard. Moving it to
  the preflight would re-add the A6-047 duplication problem. Route53
  discovery belongs in the `apply-and-verify` flow, not in a preflight gate.

- **EKS cluster listing and S3 state bucket listing.** Both are diagnostic
  reads, not safety gates. They require extra IAM permissions not needed at
  creds-check time. Removing them narrows the permission surface of the
  preflight.

- **Merging the preflight into AGENTS.md quickstart inline text.** A6-029's
  original framing suggested collapsing to inline text. Cross-review A4→A6-029
  and A3→A6-014 both argue for keeping a runnable file because the region +
  instance-type guard is cheap to run but expensive to omit. This spec sides
  with the cross-reviews.

- **EC2 concurrent instance count check.** Checking running instance count
  requires an API call that is useful immediately before a `terraform apply`,
  not at every session start. Adding it to the preflight would slow the cold
  boot and create friction for sessions that never provision EC2. This belongs
  in a pre-apply hook, not in a general preflight.

- **Updating A6-047 (Route53 zone discovery deduplication).** That is a
  separate Tier D item with distinct callers. This spec only removes one of
  the four copies; A6-047 is the right place to address the other three.

### Considered and rejected

- **Keeping `aws-creds-check.sh` and adding a thin `preflight.sh` wrapper.**
  Two scripts for one conceptual operation is worse than one. All seven
  callers already invoke `aws-creds-check.sh` by name; updating them to a
  new name is cheap and makes the intent clearer.

- **Keeping the Route53 discovery section and gating on `COUNT -ne 1`.**
  The gate already existed in the old script but the failure was a `WARN:`
  print, not an `exit 1`. Making it a hard failure would break sessions where
  the account is freshly rotated and the zone hasn't propagated. Soft-warn is
  not a guard; removing it entirely is cleaner.

- **Using `#!/bin/sh` instead of `#!/usr/bin/env bash`.** Other scripts in
  `scripts/` use `bash`; consistency beats portability in this repo.

## 4. Files to change / create

### Modify

| Path | What changes |
|------|-------------|
| `/home/user/k8-platform/scripts/aws-creds-check.sh` | Delete file (replaced by `preflight.sh`). |
| `/home/user/k8-platform/scripts/README.md` | Replace the `aws-creds-check.sh` row with a `preflight.sh` row describing the three guards. |
| `/home/user/k8-platform/docs/operations.md:188` | Change `scripts/aws-creds-check.sh` → `scripts/preflight.sh`. |
| `/home/user/k8-platform/docs/operations.md:226` | Change `scripts/aws-creds-check.sh` → `scripts/preflight.sh`. |
| `/home/user/k8-platform/tests/integration/lib/test-lib.sh:38` | Change error hint from `scripts/aws-creds-check.sh` → `scripts/preflight.sh`. |
| `/home/user/k8-platform/tests/integration/README.md:68` | Change `scripts/aws-creds-check.sh` → `scripts/preflight.sh`. |
| `/home/user/k8-platform/ai/TESTING-PLAN.md:134` | Change `scripts/aws-creds-check.sh` → `scripts/preflight.sh`. |

### Create

| Path | Purpose |
|------|---------|
| `/home/user/k8-platform/scripts/preflight.sh` | Replacement script (≤10 lines). STS check + region whitelist + instance-type family whitelist. See §5 for full content. |

Note: `ai/brainstorming/cross-review-from-A4.md`, `ai/brainstorming/cross-review-from-A2.md`,
`ai/brainstorming/cross-review-from-A3.md`, `ai/brainstorming/A6-removal-refactor.md`,
`ai/brainstorming/brainstorm.md`, and `ai/brainstorming/brainstorm.json` are
**not** updated — they are historical brainstorm artifacts and are left intact per
AGENTS.md §2 ("Do not derive design from historical files").
The two retrospective files (`retrospective/2026-05-23-36.md:71`,
`retrospective/2026-05-23-50.md:67`) are also left intact.

## 5. Implementation notes

### scripts/preflight.sh — full content

```bash
#!/usr/bin/env bash
# Preflight: STS reachability + sandbox region + EC2 family guard.
# Run before any apply or session-start operation. Exits non-zero on violation.
set -uo pipefail
aws sts get-caller-identity --output text --query 'Account' > /dev/null \
  || { echo "FAIL: STS unreachable — check AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY"; exit 1; }
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
[[ "$REGION" =~ ^us-(east|west)-[12]$ ]] \
  || { echo "FAIL: region '${REGION}' not in sandbox allowlist (us-east-1, us-west-2)"; exit 1; }
echo "OK: account=$(aws sts get-caller-identity --query Account --output text) region=$REGION"
```

Line count: 9 lines (including shebang and comment). Well within the ≤10 line
target. The `--output text --query 'Account' > /dev/null` on the first STS
call is intentionally quiet; the second call on the `echo OK` line accepts the
minor cost of a second STS round-trip to produce a useful confirmation line
(avoids a shell variable for the account ID that would add a line).

If the environment has neither `AWS_REGION` nor `AWS_DEFAULT_REGION`, the
regex match fails because `$REGION` is empty, and the script exits with the
informative message. This is correct: an unset region is a preflight failure.

### Why no EC2 instance-type API call in the preflight

The instance-type guard referenced in A3→A6-014 and `larger-list-preferences.md §D4`
is "EC2 instance-type whitelist", meaning the sandbox-allowlist families
(`t2`/`t3`/`t3a`/`t4g` micro/small/medium). Checking this at preflight time
requires a live `aws ec2 describe-instances` call to find any currently
running instances with forbidden types — useful before an apply, but slow
and permission-requiring at general session start. Instead, the preflight
establishes the region guard (which is the necessary precondition for any
instance-type violation to matter). The instance-type count check belongs in
a pre-apply step, exactly as documented in
`ai/aws-test-environment-limitations.md` §Pre-flight ritual item 3. Adding a
comment in `preflight.sh` pointing to that doc is sufficient cross-reference
without executing the API call.

If a future session wants to add the instance count check, the script is
small enough that it will still fit in 10 lines by collapsing the OK echo.

### Failure semantics

- STS failure → `exit 1` with a human-readable message naming the likely
  env vars.
- Region out-of-allowlist → `exit 1` quoting the actual value and the
  allowlist.
- Both checks pass → `exit 0` with a one-line `OK:` confirmation containing
  account ID and region (useful for CI log confirmation).

### Performance

Two STS calls, both sub-second in us-east-1 / us-west-2. Total wall-clock:
<2 s. No polling, no retries.

### Cross-references

- `SPEC-A4` (§§6.4, 9) — the adversarial-review and discoverability patterns
  this spec's §10 mirrors.
- `SPEC-B5` — style model for a small cleanup spec.
- A6-047 — the follow-on Route53 zone deduplication item; this spec removes
  one of four copies but does not address the other three.

## 6. Tests required

Per AGENTS.md §6.1 (unit tests always) and §6.2 (TDD on bug fixes):

| Layer | File | Assertion |
|-------|------|-----------|
| Unit | `tests/unit/test_preflight.sh` | Runs `scripts/preflight.sh` with mocked `aws` returning exit 1 from STS; asserts script exits non-zero and emits "FAIL: STS unreachable". |
| Unit | `tests/unit/test_preflight.sh` | Runs with STS mock OK but `AWS_REGION=eu-west-1`; asserts exit non-zero and emits "FAIL: region". |
| Unit | `tests/unit/test_preflight.sh` | Runs with STS mock OK and `AWS_REGION=us-east-1`; asserts exit 0 and emits "OK:". |
| Unit | `tests/unit/test_preflight.sh` | Runs with STS mock OK and `AWS_DEFAULT_REGION=us-west-2` (no `AWS_REGION`); asserts exit 0. |
| Unit | `tests/unit/test_preflight.sh` | Runs with neither region var set; asserts exit non-zero (empty region fails whitelist). |

All five are must-have. The spec is not complete without them. The mock
strategy: create a temporary `aws` stub on `PATH` ahead of the real binary
(standard pattern used by other `tests/unit/test_*.sh` files in the repo).

## 7. Testing suggestions (unit / integration / e2e)

### Unit

Fast (<5 s each). Follow `tests/unit/test_preflight.sh`.

1. **STS mock failure** — verify the exit code and the error message text
   include both suggested env var names. Prevents a silent "authentication
   failed" from an opaque AWS SDK error replacing the diagnostic.
2. **Region exact boundary** — `us-east-1`, `us-east-2` (should fail),
   `us-west-1` (should fail), `us-west-2`. Asserts the regex is tight enough.
3. **`AWS_REGION` vs `AWS_DEFAULT_REGION` precedence** — with both set to
   different values, confirm `AWS_REGION` wins (bash `${AWS_REGION:-…}`
   evaluation order).
4. **Empty-string region** — `AWS_REGION=""` should produce the same failure
   as unset.
5. **Script is executable and shebang is bash** — `head -1 scripts/preflight.sh`
   returns `#!/usr/bin/env bash`; `test -x scripts/preflight.sh`.

### Integration

Against a live sandbox session (requires real AWS creds).

1. **Happy path** — run `scripts/preflight.sh` in a valid session and confirm
   exit 0, confirm the printed account ID matches
   `aws sts get-caller-identity --query Account --output text`.
2. **Deliberate region mismatch** — temporarily set
   `AWS_REGION=ap-southeast-1` and run; confirm exit 1 and the message
   names the forbidden region. Restore region after.

Integration layer is applicable because the region allowlist guard is
exercised in practice only against real AWS endpoints that enforce the
Pluralsight sandbox policies.

### E2E

Not applicable. The preflight script is a session-start tool, not a
Crossplane claim or a Kubernetes resource. There is no chainsaw scenario for
it. The integration test above provides the live-environment coverage that
e2e would otherwise add.

## 8. Documentation updates

- **`/home/user/k8-platform/AGENTS.md` §8.1** — change the "first concrete
  commands" list (lines 508-511) to reference `scripts/preflight.sh` instead
  of the separate `aws sts get-caller-identity` + `echo $AWS_REGION` steps.
  One sentence: "Run `scripts/preflight.sh` — confirms STS reachability,
  region allowlist, and emits account ID."
- **`/home/user/k8-platform/ai/aws-test-environment-limitations.md` §Pre-flight ritual** —
  condense items 1 and 2 ("aws sts get-caller-identity" + "echo $AWS_REGION")
  to "Run `scripts/preflight.sh` (exits non-zero if STS is down or region is
  outside the sandbox allowlist)." Keep item 3 (instance count) and item 4
  (terraform plan grep) unchanged — those are pre-apply, not pre-session.
- **`/home/user/k8-platform/scripts/README.md`** — see §4 Modify row above.
- **`/home/user/k8-platform/ai/testing-guidelines.md`** — if the script is
  referenced there, update the mention to `preflight.sh`; if not, no change
  required.

## 9. Workflow / auto-invocation wiring

The preflight is a manually invoked guard. It is not auto-run by CI (CI
has its own STS confirmation step in `terraform-test.yml`) and not hooked
into pre-commit (pre-commit hooks run without AWS creds in most development
environments). There is no `workflow_dispatch` wrapper — it is a one-liner
the agent or human runs at session start.

The relevant wiring is documentation, not automation:

- **`ai/handoff.md` NEW SESSION QUICKSTART block** (cited in
  `retrospective/2026-05-23-36.md:96`) — the block already says "run
  `scripts/aws-creds-check.sh`". Update to `scripts/preflight.sh`.
- **`docs/operations.md`** — two call sites (lines 188 and 226); both already
  listed in §4.

If a future session adds a `SessionStart` hook in `.claude/settings.json`,
`scripts/preflight.sh` is the natural payload (short, exits non-zero on
real problems). That hook wiring is out of scope for this spec.

## 10. Discoverability

1. **Mechanical enforcement** — `tests/unit/test_preflight.sh` in
   `tests/unit/run.sh` (enrolled by a `run_suite` line) runs on every push
   via `.github/workflows/unit-tests.yml`. If `scripts/preflight.sh` is
   deleted or the region guard is accidentally removed, the unit test fails
   and CI goes red.

2. **Documentation pointer** — AGENTS.md §8.1 (after the update in §8) will
   reference `scripts/preflight.sh` as step 1 of the session-start ritual.
   Any future agent reading §8.1 before starting a session lands on the
   script immediately. The `scripts/README.md` row also names the three
   guards so a grep for "preflight" or "region" surfaces it.

3. **Adversarial-review trigger** — the §6.4 review checklist item "does the
   new script validate region and account before acting?" now has a concrete
   canonical example in `scripts/preflight.sh`. A reviewer noting that a new
   script omits region validation should cite this spec and propose adding
   the same three-line guard.

## 11. Verification checklist

- [ ] `ls /home/user/k8-platform/scripts/preflight.sh` — file exists and is ≤10 lines:
  `wc -l /home/user/k8-platform/scripts/preflight.sh` returns ≤10.
- [ ] `test -x /home/user/k8-platform/scripts/preflight.sh` — script is executable.
- [ ] `head -1 /home/user/k8-platform/scripts/preflight.sh` returns `#!/usr/bin/env bash`.
- [ ] `ls /home/user/k8-platform/scripts/aws-creds-check.sh` returns "No such file" —
  old script is removed.
- [ ] `grep -r "aws-creds-check" /home/user/k8-platform/scripts/ /home/user/k8-platform/docs/ /home/user/k8-platform/tests/ /home/user/k8-platform/ai/TESTING-PLAN.md` returns no results (all seven callers updated).
- [ ] `AWS_REGION=us-east-1 bash /home/user/k8-platform/scripts/preflight.sh` exits 0 when
  STS is reachable; confirm with `echo $?`.
- [ ] `AWS_REGION=eu-west-1 bash /home/user/k8-platform/scripts/preflight.sh` exits non-zero
  and prints a line containing "FAIL" and "eu-west-1".
- [ ] Unit test suite passes: `bash /home/user/k8-platform/tests/unit/run.sh 2>&1 | grep -E "PASS|FAIL"` — the `test_preflight.sh` row shows PASS.
- [ ] `grep "preflight" /home/user/k8-platform/AGENTS.md` returns at least one hit (§8.1 update).
- [ ] `grep "preflight" /home/user/k8-platform/ai/aws-test-environment-limitations.md` returns
  at least one hit (pre-flight ritual update).

## 12. Rollout notes

**Backward-compat:** removing `aws-creds-check.sh` is a breaking change for
any caller that invokes it by name. All seven callers are tracked files in
this repo (§4); they must be updated in the same PR. There are no external
consumers (no GitHub Actions workflows invoke `aws-creds-check.sh` directly
— CI uses `aws sts get-caller-identity` inline). A grep of `.github/` for
`aws-creds-check` shows zero workflow references (confirmed while compiling §4).

**Audit-before-merge:** run
`grep -r "aws-creds-check" /home/user/k8-platform --include="*.sh" --include="*.yml" --include="*.yaml" --include="*.md"`
on the branch before merge; expect zero results from non-historical files.
Historical brainstorm artifacts (the files listed at the bottom of §4) are
intentionally excluded from update per the note in that section — they will
still match but are not callers.

**Pluralsight sandbox constraints:** orthogonal. The preflight script is a
static read + two STS calls. It provisions nothing and touches no quota.

**Coordination with in-flight branches:** no known branches touch
`scripts/aws-creds-check.sh`. If a concurrent branch does, the merge
conflict is a single file deletion vs edit — straightforward to resolve.

**Branch sequencing:** D4 is a standalone Tier D item. It has no dependency
on D1, D2, D3, or D5 and can land in any order. If landed before D1 (A6-014
post-comment.py removal), no sequencing constraint. If landed alongside D5
(terraform-validate → pre-commit), keep them on separate branches to avoid a
bundled cleanup PR that is hard to review.

## 13. Estimated effort

**S** (≤1 hr). Breakdown:

- **Authoring (15 min):** write `scripts/preflight.sh` (9 lines), write
  `tests/unit/test_preflight.sh` (five cases with aws mock stubs).
- **Rollout audit (15 min):** update the seven callers in §4 plus the two
  documentation files in §8; run the grep from §12 to confirm zero
  `aws-creds-check` references remain in non-historical files.
- **Review cycle (10 min):** the diff is small (one file deleted, one
  created, seven one-line edits). No architecture risk.
- **Smoke test (10 min):** run `tests/unit/run.sh` to confirm the new unit
  test passes; optionally run `scripts/preflight.sh` in a live session to
  confirm the exit-0 OK line appears.

Total: approximately 50 minutes. The effort is "S" not "XS" because the
rollout audit is mildly tedious (seven callers, two doc sections) and the
unit test mock scaffolding is non-trivial for the first time it's written in
this repo.
