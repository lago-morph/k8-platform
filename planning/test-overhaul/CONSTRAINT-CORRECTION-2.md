# Constraint correction #2 (2026-06-07) — CI is not the trigger; cluster tests are dispatch-only

**Owner correction. Reframes the test-execution/trigger model. Apply over the
synthesized AND final plans.**

> "You can't rely on GitHub Actions for your tests. Those happen at PR time, which may
> be independent from the actual build process. Adding things that require a cluster
> (even kind) is a very bad idea in CI unless they are runs you manually trigger, not
> ones tied to a PR or a commit."

## What this means

1. **The coupling is to the BUILD, not to CI.** "Live verification runs every time we
   bring the cluster up" (requirement #1) means the **bring-up procedure itself
   invokes the verification suite** (e.g. the operator/agent's `apply-and-verify` /
   cluster-creation flow runs `verify-platform.sh` as its final phase). PR/push CI is
   DECOUPLED from the actual build and must NOT be the thing relied on to run the
   verification. "Coupled to the change" = coupled to the build that applies the
   change, not to a commit's PR check.

2. **Anything that needs a cluster — even kind — is `workflow_dispatch`-ONLY in
   GitHub Actions.** Never push-triggered, never PR-triggered. (This matches the repo's
   existing pattern: chainsaw.yml and terraform-test.yml are dispatch-only; AGENTS §6.7.)
   Cluster/live behavioral tests are run by the build flow or by an explicit manual
   dispatch — not automatically on every commit/PR.

3. **Only no-cluster STATIC checks may run on push/PR.** Lints, schema/kubeconform,
   the derived-coverage-manifest PARSE (static), the no-wildcard IAM ceiling lint,
   `irsa_trust_validator.py` static sweeps, helm-template render asserts. These need no
   cluster and are safe as push checks.

## Required changes to the plan

- **Move the on-by-default trigger OUT of "PR CI" and INTO the bring-up procedure.**
  The build/bring-up (apply-and-verify, the cluster-creation flow, the spoke
  reconciliation hook) runs the live suite as part of itself. That is the real
  "every bring-up" guarantee.
- **Reclassify the enforcement layers:**
  - *Push/PR CI (automatic):* static-only lints + coverage-manifest parse + ceiling
    lint + "is the live-suite wired into the bring-up and on-by-default" invariant
    checks. NO cluster.
  - *Build-time (coupled, on by default):* the full live behavioral/negative/precondition
    suite, run by the bring-up. all-skipped ⇒ RED applies HERE.
  - *Manual dispatch (workflow_dispatch):* kind-based render/admit and any ad-hoc live
    runs. Never auto-triggered.
- **The anti-silent-regression gate cannot depend on a PR-time cluster run.** A
  push-time check may at most verify *static evidence* (e.g. that a recorded green
  build-suite result exists for the deployed SHA/cluster), but the PRIMARY guarantee is
  the build coupling, not the PR check. Do not gate correctness on PR-time cluster work.
- **Re-verify** that "on by default", "disable-able but not disabled", "all-skipped ⇒
  RED", and "coupled to the change" all still hold under this build-coupled model
  (they should — the trigger just moves from CI to the build).
- Combine with CONSTRAINT-CORRECTION.md: workflow files ARE editable via jentic, so the
  dispatch-only workflows and any build-flow wiring can be landed — just keep
  cluster-requiring workflows `workflow_dispatch`-only.
