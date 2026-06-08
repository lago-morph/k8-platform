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

### 2. Excise the nightly / non-gating lane entirely (OI-2026-06-06-4) — ✅ mechanism excised in PR #188 (2026-06-08)
- [x] Deleted the `CHAINSAW_INCLUDE_REALAWS` exclusion block in `tests/chainsaw/run.sh`.
- [x] Deleted the two `REAL-AWS / NIGHTLY` scenarios
      `tests/chainsaw/xdatabase/{01-claim-creates-rds,02-deletion-cleanup}` and
      refreshed the stale "nightly" comments in both `00-xrd-establishes` scenarios.
- [x] Deleted `tests/unit/test_chainsaw_realaws_gated.sh` and de-enumerated it from
      `tests/unit/run.sh` (it was not enumerated in `.github/workflows/unit-tests.yml`).
- [x] Removed the real-AWS/nightly exemption in
      `tests/unit/test_chainsaw_golden_files_present.sh`.
- [ ] **(carried to item 4)** Move the RDS behavioral coverage to the **gating** live
      suite (`tests/live/`, fail-closed; registry owes `rds.aws.m.upbound.io/Instance`).
      Deferred because a real-AWS check can only *gate* once the live suite is wired
      fail-closed (item 4) — until then it would be a non-gating lane, the very thing
      excised. Tracked with the capstone.
- **Acceptance (mechanism):** chainsaw `27112866450` green with the exclusion removed;
      repo grep for the nightly mechanism returns only historical / ADR-0009 records.
      The additive gating RDS live check lands with item 4.

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

### 4. Make the live suite actually gate — the test-overhaul capstone — ✅ MECHANISM in PR #190 (2026-06-08), scope-and-grow
- [x] Wired the live suite into a dedicated `workflow_dispatch` producer
      (`.github/workflows/live-verify.yml` → `.github/scripts/live-verify-run.sh`,
      like chainsaw.yml is separate from terraform-test.yml) running
      `tests/live/run.sh` under the **scoped verifier/reaper role** (assume-role +
      `live-verify` session tag); emits the machine-emitted `live-evidence`
      artifact on the clean pass.
- [x] Fail-closed gate `.github/workflows/live-evidence-verify.yml` +
      `live-evidence-gate.sh` (`fetch_evidence` de-stubbed to join the producer's
      artifacts) + the static wired/gating/scoped lint
      `tests/unit/test_live_suite_wired.sh`.
- [x] Found+fixed a latent bug by spike: `verifier_role.tf` trust required a
      `live-verify` request tag but didn't grant `sts:TagSession` → tagged
      assume-role failed AccessDenied. Added `sts:TagSession` (applied via tf).
- **Acceptance MET:** `live-evidence-verify` went **RED automatically** on this
      branch's config changes with no fresh evidence (runs `27115041734`,
      `27115158959`); the producer (run live under the scoped role) emits valid
      evidence and the gate flips **GREEN** for it (validated: gate GREEN on the
      real evidence, RED on empty, RED on verify-only-vs-full). The RDS behavioral
      check passes live. **Pending (mechanical, post-merge):** one CI artifact
      round-trip — GitHub won't `workflow_dispatch` `live-verify.yml` until it is on
      `main`, so dispatch it once after #190 merges to confirm the artifact
      upload→API-fetch end-to-end.
- **NEXT SESSION (owner-directed):** author the **~13 remaining per-kind
      behavioral checks** (acm Certificate/Validation, eks Cluster/NodeGroup/
      AccessEntry/AccessPolicyAssociation, iam Role/RolePolicy/RolePolicyAttachment/
      OIDCProvider, route53 Record, secretsmanager Secret, ExternalSecret) so the
      gate's coverage grows from the current `rds Instance` to the full set; flip
      each registry `defended_by` off `pending:P*` as it lands.

### 5. (Infra hygiene — small, durable) stop the session-start potholes — ✅ DONE in PR #189 (2026-06-08)
- [x] **ADR numbering collisions** — added `tests/unit/test_adr_numbering.sh`
      (fail-closed duplicate-number lint) + `scripts/next-adr-number.sh` (prints
      the next free number, reminds to fetch main + check open PRs).
- [x] **Stale branch off `main`** — `.claude/hooks/session-start.sh` now fetches
      `origin/main` and WARNs (non-blocking) if the checkout is behind, before any
      ADR numbering or new work.

---

## Done bar
This list is empty → the gate is trustworthy (red=real, green=done, no nightly),
#184 is merged and validated, and the live suite gates fail-closed. **Then, and
only then, resume new implementation** (the test-strategy continuation's P0 spike
is the first item there; see `ai/handoff.md`).
