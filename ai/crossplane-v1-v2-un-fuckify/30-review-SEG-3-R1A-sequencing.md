# 30 — Review: SEG-3 test infra plan — angle R1A sequencing

**Reviewer:** adversarial subagent (execution + sequencing angle)
**Target:** `20-plan-SEG-3-test-infra.md`
**Date:** 2026-05-26

---

## Verdict

**REVISE-MAJOR**

The lockstep diagnosis is correct and the stacked-PR mechanism is the right tool, but the plan glosses over two ordering hazards that, if either fires, leave main red for unrelated PRs.

## Strengths

- Correctly identifies the unit composition tests (`test_platform_{secret,cluster}_composition.sh`) as the every-push gating signal and the single biggest blast risk (§2.1, §5).
- The §2.1 a/b/c framing names the right tradeoff and option (c) — atomic merge — is the right choice.
- Failure-recovery row "Unit composition tests go red on main after SEG-1 merges without SEG-3" is a real and specific runbook entry.
- Correctly invokes AGENTS.md §6.7 dispatch-then-PR for chainsaw, giving a deliberate staging buffer.

## Flaws

1. **Stacked-PR merge order is not enforced.** §2.1 says child PR opens with `base = SEG-1's branch` and "GitHub auto-retargets onto main when SEG-1 merges". True, but the plan never says SEG-1 and SEG-3 must merge in the *same merge train* (within minutes). Between SEG-1 merging and SEG-3 retargeting+merging, ANY push to ANY branch trips the unit-composition assertion at L41. The plan needs an explicit "merge SEG-3 within N minutes of SEG-1, or hold SEG-1" gate. Mitigation suggestion: use GitHub merge queue, or merge SEG-3 as a stack via `gh pr merge --auto` chained to SEG-1's merge, or squash both PRs into one.

2. **SEG-4 fixture race is unaddressed.** §6 says SEG-4 owns `tests/unit/fixtures/crossplane-trace/*.json` and `kubeconform/*.yaml`. Per impact doc §"kubeconform fixtures", three of those fixtures cause `test_kubeconform_manifests.sh` (every-push) to FAIL (expected-invalid → statusSkipped) the moment schemas regenerate to `*.m.upbound.io/`. SEG-3 explicitly disclaims this file but `test_kubeconform_manifests.sh` runs in `unit-tests.yml` push-gate too. If SEG-4 lands before SEG-3 (or independently), every push goes red. The plan needs an explicit SEG-3↔SEG-4 sequencing constraint, not just a soft dependency in §6.

3. **Integration tests are dispatch-only — verification gap.** Open question 1 (cluster-scoped MR in v2) for `05_*.sh` cannot be resolved without a live cluster, yet there is no `integration-tests.yml` dispatch step in the §2.4 verification flow — only chainsaw is dispatched. SEG-3 may merge with 05/06/11 broken and the failure surface only at SEG-2's phase-2 verify. Add an explicit "dispatch integration-tests.yml against the SHA" step parallel to chainsaw dispatch.

4. **Open question 2 (`providerConfigRef.kind` value) blocks edits.** §6 calls this "single most consequential coupling" but §7 budgets only 0.5h for "read SEG-1's published deltas". If SEG-1's choice arrives mid-authoring, the new assertions (§2.3 row "NEW") need rework. Make this a hard gate, not a soft read.

## Minor

- §2.3 row for `run.sh` L230 silently picks `ProviderConfig` (namespaced) over `ClusterProviderConfig` — but SEG-1 §1 commits to `ClusterProviderConfig`. Inconsistent.
- Chainsaw dispatch iteration estimate (2h / 3 runs) seems light given AWS-cred-required scenarios.
