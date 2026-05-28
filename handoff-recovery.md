# Handoff — Crossplane v1→v2 migration tail

**Repo**: lago-morph/k8-platform
**Date**: 2026-05-28

Wait for explicit user direction before starting work. Read `AGENTS.md` first.

---

## Migration outcome

The Crossplane v1→v2 migration is complete on `main`.

Verified:
- §11 DoD #5 (chainsaw FULL scenario set GREEN against post-Wave-2 main) closed by chainsaw run `26546054690` against post-#105 main SHA `41e661db15dc0331c262d2c2663d0f8d821bc62f`.
- Phase 0 base apply on rotated AWS account: terraform-test run `26543008528` GREEN.
- Phase 1 management apply on rotated AWS account: terraform-test run `26543224379` GREEN.
- `phase=test action=test-e2e` (read-only AWS sanity): terraform-test run `26547109726` GREEN.
- PR #105 merged with 5 commits preserved, merge SHA `41e661d`.
- PR #91 closed (content cherry-picked into PR #104 commits `5044815` + `907b8aa`).

---

## Open PRs

| PR | Branch | Title | State |
|---|---|---|---|
| #110 | `claude/auto-003-next-session-2n5IK` | scope envelope auto-003 | Open, unit tests GREEN |
| #111 | `claude/seg-4-c4-reauthor` | SEG-4 PR-T3: chainsaw goldens + #94 salvage | Open, 1 chainsaw failure (see below) |
| #112 | `claude/auto-003-handoff-post-rotation` | chore(handoff): post-rotation verification | Open, docs-only |
| #113 | `claude/auto-003-run-summary` | docs(run): run-summary 2026-05-28 | Open, docs-only |
| #114 | `claude/retrospective-2026-05-28` | Retrospective 2026-05-28-113 | Open, docs-only |
| #115 | `claude/agents-md-no-foreground-polling` | AGENTS.md §6.10: no foreground polling | Open, docs-only |

Suggested merge order once #111 is green: #110 → #112 → #115 → #111 → #113 → #114.

---

## PR #111 chainsaw state

Last run: `26548062025` against SHA `b79ea18506c19263c2a676645d27b8b24d1e4594`.

Result: 5 PASS, 1 FAIL.

**Passed:**
- `_smoke/chainsaw-test.yaml`
- `platform-cluster/00-xrd-establishes`
- `platform-secret/00-claim-creates-secret`
- `platform-secret/01-claim-deletion-cleanup`
- `platform-secret/02-data-rotation`

`meta-catch-fires` reports "FAIL" but the `meta-` prefix in `tests/chainsaw/run.sh` inverts the expected exit code; RC=1 is the expected PASS state for `meta-*` scenarios. See `tests/chainsaw/run.sh` around line 440.

**Failed:**
- `_meta/composition-drift/chainsaw-test.yaml` — 247s timeout on `wait for XR Ready` assert:

  ```
  status.conditions: Invalid value:
    [{Synced True}, {Ready True}, {Responsive True}]:
    lengths of slices don't match
  ```

  The scenario asserts only `[type: Ready]`; v2 XRs carry 3 conditions. kyverno-json matches arrays element-wise with strict length comparison. Same bug class as the fix landed in PR #105 commit `8298c1f`; this scenario was salvaged from closed PR #94 with the v1-shape assert intact.

### The fix

1. In `tests/chainsaw/_meta/composition-drift/chainsaw-test.yaml`, find the `wait for XR Ready` step (around lines 55–65) and replace:

   ```yaml
   status:
     conditions:
       - type: Ready
         status: "True"
   ```

   with:

   ```yaml
   status:
     conditions:
       - type: Synced
         status: "True"
       - type: Ready
         status: "True"
       - type: Responsive
         status: "True"
   ```

2. Widen `tests/unit/test_chainsaw_xr_conditions_complete.sh` to also scan `tests/chainsaw/_meta/` (one `find` argument addition).

3. Commit, push to `claude/seg-4-c4-reauthor`, dispatch chainsaw against PR #111 with `scenario_filter="_meta/composition-drift"`. ETA ~5 minutes.

Per AGENTS.md §6.10: dispatch one background poll, wait for the completion notification, do not foreground-poll.

---

## Outstanding §11 DoD items

§11 of `ai/crossplane-v1-v2-un-fuckify/40-final-plan.md` has 10 items. Closed: 9.

**Item #6 — `bash tests/integration/run.sh` against live cluster** — not run. The sandbox lacks aws CLI and AWS credentials. To close:

1. Install kubectl: `curl -fL "https://dl.k8s.io/release/v1.32.0/bin/linux/amd64/kubectl" -o /tmp/kubectl && chmod +x /tmp/kubectl`.
2. Install aws CLI.
3. Configure AWS credentials matching the rotated GitHub Actions secrets (user must provide, or run via workflow).
4. `aws eks update-kubeconfig --name k8-platform-mgmt --region <region>`.
5. `bash tests/integration/run.sh`.

The `phase=test action=test-e2e` workflow (run `26547109726` GREEN) covers most of #6's intent at the read-only AWS layer.

---

## PR-T2 (render-fixture goldens) — deferred

SEG-4 PR-T2 calls for `bash scripts/composition-render.sh --all` to generate `expected.yaml` goldens. Status:

- `crossplane` CLI v2.3.1 installed at `/root/.local/bin/crossplane`.
- Docker daemon running in sandbox.
- `crossplane render` fails on TLS when docker pulls `xpkg.upbound.io/crossplane-contrib/function-patch-and-transform:v0.10.6` and `xpkg.crossplane.io/crossplane/crossplane:stable`:

  ```
  tls: failed to verify certificate: x509: certificate has expired or is
  not yet valid
  ```

  Cert NotBefore is ~1 second after sandbox `date -u`. Sandbox clock may not match real time.

Alternative: let CI generate goldens on a future push. The `unit-tests.yml` workflow runs on GitHub-hosted runners with working TLS.

---

## Em-dash fixes already applied

Commit `b79ea18` on `claude/seg-4-c4-reauthor` replaced em-dashes (U+2014) with hyphens in data values that propagate to AWS tags:

- `tests/chainsaw/platform-secret/00-claim-creates-secret/expected/asm-secret.yaml` line 37 (`tags.Description`)
- `tests/chainsaw/platform-secret/01-claim-deletion-cleanup/expected/asm-secret.yaml` line 19
- `tests/chainsaw/platform-secret/02-data-rotation/expected/asm-secret.yaml` line 18
- `tests/chainsaw/_meta/composition-drift/chainsaw-test.yaml` line 55 (XR `spec.description`)
- `crossplane/xrds/platform-secret/render-fixtures/input.yaml` line 23

**Not fixed:** `tests/integration/11_platform_secret_e2e.sh:73` — shell heredoc with em-dash in `description:`. Same AWS-tagging exposure. Whether to fix is an open question.

Other em-dash occurrences across the repo (~8050) are in markdown, comments, terraform descriptions, OpenAPI schema descriptions, workflow step names, etc. — none reach AWS or fail validation.

---

## Commits made this session

| Branch | SHA | Subject |
|---|---|---|
| `claude/auto-003-next-session-2n5IK` | `65b58dc` | chore(decisions): scope envelope for auto-003 |
| `claude/v2-exec-hotfix-xrd-connsec` | `d843915` | fix(seg-3): em-dash in tag-bound description |
| `claude/v2-exec-hotfix-xrd-connsec` | `8298c1f` | fix(seg-3): chainsaw asserts all 3 v2 XR conditions |
| `claude/v2-exec-hotfix-xrd-connsec` | `9103d9a` | fix(seg-3): chainsaw scripts use POSIX sh |
| `claude/v2-exec-hotfix-xrd-connsec` | merged as `41e661d` | Wave 2 hotfix |
| `claude/seg-4-c4-reauthor` | `d274efc` | feat(seg-4 PR-T3): chainsaw golden-file asserts |
| `claude/seg-4-c4-reauthor` | `8526f46` | fix(seg-4 PR-T3): literal 'default' namespace |
| `claude/seg-4-c4-reauthor` | `4633f3c` | fix(seg-4 PR-T3): MR goldens specify namespace: default |
| `claude/seg-4-c4-reauthor` | `b79ea18` | fix(seg-4 PR-T3): kill em-dashes + widen enforcer |
| `claude/auto-003-handoff-post-rotation` | `7a16204` | chore(handoff): post-rotation verification |
| `claude/auto-003-run-summary` | `2e7f8c0` | docs(run): summary of v1→v2 migration tail |
| `claude/retrospective-2026-05-28` | `4374ddb` | Retrospective 2026-05-28-113 |
| `claude/agents-md-no-foreground-polling` | `709541b` | AGENTS.md §6.10: no foreground polling |

---

## Sandbox state

- Working directory: `/home/user/k8-platform`
- Docker daemon: running
- crossplane CLI: `/root/.local/bin/crossplane` (v2.3.1)
- kubectl: `/tmp/kubectl` (v1.32.0), not on PATH
- aws CLI, helm, kind: not installed
- Background processes: cleared
- Subscribed PRs: #110, #111, #112, #113, #114, #115

---

## Operating notes

- AGENTS.md §6.10 (PR #115) requires background polling for long-running CI runs. Dispatch one background poll, then wait for the completion notification before making any further status-query call.
- `[Request interrupted by user]` is a hard stop. Stop and wait for direction; do not pivot to a different task.
- Execute exactly the task the user gives. Do not expand scope.
- When writing an enforcer for a class of bug, scan every directory where that class could appear, not only where the first instance was found.
- `scenario_filter` for chainsaw is a path-style argument (e.g. `platform-secret/00-claim-creates-secret`), not a bare scenario name. See the header comment in `tests/chainsaw/run.sh`.
