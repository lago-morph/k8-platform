# Testing / infra debt burndown

**Owner-directed (2026-06-07):** clear this list **before any new implementation
(feature) work.** The recurring pain hasn't been the features — it's a test gate
you can't trust (flakes you re-kick, real-AWS checks hidden in a nightly that
never blocks) plus session-infra potholes. This is the *finite* list of those
tollbooths, in paydown order. Burn it down; don't let it grow. When it's empty,
red means red, green means done, and feature work stops being a minefield.

Rules of engagement (the guardrails written this session):
- **AGENTS §6.34** — verify behavior coupled to the build, under the real identity (ADR-0006).
- **AGENTS §6.35** — never mark done on a manually-modified build; verify on a clean build.
- **AGENTS §6.36** — a red gate is real; no nightly / no non-gating lanes; fix or delete, never re-kick.

Prerequisite for everything live below: a fresh account with phases 0→1 up
(account rotates, §8.4; run `scripts/whereami.sh` first).

---

## Burndown (do in order)

### 1. Make the chainsaw gate honest — deterministic, no flakes ✅ DONE (2026-06-08)
- [x] **1a. `claim-deletion-cleanup` ASM-deletion check → deterministic poll.**
      Replaced the one-shot `describe-secret` with a bounded poll accepting
      NotFound **or** `DeletedDate`. File:
      `tests/chainsaw/platform-secret/01-claim-deletion-cleanup/chainsaw-test.yaml`.
- [x] **1b. Audited the rest of the gating chainsaw set.** Made deterministic:
      `00-claim-creates-secret`'s ASM-existence check → bounded poll;
      `02-data-rotation`'s initial out-of-band `put-secret-value` → bounded retry.
      Widened the XR-Ready wait bound to 600s on the three secret-provisioning
      scenarios (intermittent slow ASM converge, OI-2026-05-28-1 Issue A; a stuck
      MR still fails at the bound, so not masked). `composition-drift` audited —
      passed green at its existing bound, no one-shot real-AWS assert.
- **Acceptance MET:** chainsaw run `27111014995` went green *honestly* (7/7, no
      re-kick) on #184 HEAD `89836cc`. The fix was folded into #184 (the abandoned
      #186 was closed) so there is a single `main` vs #184 line.

### 2. Excise the nightly / non-gating lane entirely (OI-2026-06-06-4, REOPENED)
- [ ] Delete the `CHAINSAW_INCLUDE_REALAWS` exclusion block in
      `tests/chainsaw/run.sh` (~lines 406-425).
- [ ] Delete the `REAL-AWS / NIGHTLY` headers on
      `tests/chainsaw/xdatabase/01-claim-creates-rds` + `02-deletion-cleanup`
      (and the stale comment in `xdatabase/00-xrd-establishes`).
- [ ] Delete `tests/unit/test_chainsaw_realaws_gated.sh` (it *mandates* the disease);
      de-enumerate from `.github/workflows/unit-tests.yml` + `tests/unit/run.sh`.
- [ ] Remove the real-AWS/nightly exemption in
      `tests/unit/test_chainsaw_golden_files_present.sh`.
- [ ] Move the RDS behavioral coverage to the **gating** live suite
      (`tests/live/`, fail-closed; registry already owes it as
      `rds.aws.m.upbound.io/Instance: pending:P2`) — a real-AWS check that gates
      on dispatch, NOT a schedule.
- **Acceptance:** repo grep for `nightly` / `non-gating` / `CHAINSAW_INCLUDE_REALAWS`
      / `REAL-AWS` returns **only** historical `retrospective/`, `planning/`,
      `ai/brainstorming/` records — nothing live. Every behavioral check gates.

### 3. ✅ FULLY VALIDATED sandbox-kubectl (PR #184) ON A CLEAN BUILD, then merged (2026-06-08)
- [x] Clean build from merged `main`: phase 0 (`base`) + phase 1 (`management`)
      applied from `main` via `terraform-test.yml apply-and-verify` (runs
      `27111305299`, `27111334651`). Spoke `k8-platform-services` created by
      **ArgoCD GitOps** — triggered the committed-source sync of the
      `platform-cluster-claim` Application (a `kubectl patch … operation.sync
      revision=main`, i.e. "click Sync"), **no paused auto-sync and no manual
      `kubectl apply`** of any manifest.
- [x] `scripts/sandbox-kubeconfig.sh --exec kubectl get nodes` through the shared
      relay returned: **hub `k8-platform-mgmt` → 3 Ready**, **spoke
      `k8-platform-services` → 2 Ready**. The committed live check
      `tests/live/checks/after/sandbox-kubectl-relay.sh` PASSED for both
      (`COVERS ec2.aws.m.upbound.io/SecurityGroupRule`).
- [x] Merged **#184** (merge commit `bd1d45a`) — green gate (chainsaw `27111014995`)
      + the clean-build proof above. Owner-directed merge-first, then build-from-main.

### 4. (Deeper) Make the live suite actually gate — the test-overhaul capstone
- [ ] Wire `tests/live/run.sh` into the dispatch apply-and-verify job under the
      scoped verifier/reaper role; emit the clean-pass evidence artifact; wire the
      fail-closed live-evidence gate + the static wired/gating/scoped lints (auto-013
      CARRIED-FORWARD). This is what makes "behavioral checks gate, fail-closed"
      real rather than aspirational — the structural cure for the whole class.
- **Acceptance:** a config reconciled without fresh live evidence goes RED automatically.

### 5. (Infra hygiene — small, durable) stop the session-start potholes
- [ ] **ADR numbering collisions** (cost real time this session: `0006` was taken,
      `0007` too). Either switch committed `docs/decisions/` to hash IDs like the
      retrospectives already use, or add a one-line "pick the next free number from
      `ls docs/decisions/` AND open PRs" check. Cheap; stops recurring.
- [ ] **Stale branch off `main`** — the sandbox clones once at container start, so a
      session can be behind `main` (it was, by 4 commits incl. the ADRs above).
      Habit: `git fetch origin main` + rebase/merge at session start before
      numbering or basing new work.

---

## Done bar
This list is empty → the gate is trustworthy (red=real, green=done, no nightly),
#184 is merged and validated, and the live suite gates fail-closed. **Then, and
only then, resume new implementation** (the test-strategy continuation's P0 spike
is the first item there; see `ai/handoff.md`).
