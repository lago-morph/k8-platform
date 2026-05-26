# 30 — SEG-5 Review (Round 1, Reviewer B — correctness angle)

**Verdict:** REVISE-MAJOR

## What the plan does well

- Right disposition for **#97** (path-filter fix is v2-agnostic and trivially correct on its own merits — verified the diff is +11/-0 against `tests/unit/test_kubeconform_manifests.sh` only, no AWS-group references). Merging first to make CI signal legible is the correct sequencing.
- Right ordering for **#98** as the migration entry point — the failure-mode shift (from `PendingExternalResource` to admission rejection) is the diagnostic the project needs.
- Reasonably complete enumeration for #87/#90/#92/#93 follow-ups.

## Correctness flaws

1. **PR #96 is MERGED, not a numbering gap.** Verified via `mcp__github__pull_request_read`: #96 is "testing-guidelines §10: read the failure log before hypothesizing" — merged 2026-05-25T23:02:18Z by jonathanmanton. The plan's §5 table row for #96 ("gap in numbering — appears to be a closed-without-merge or housekeeping PR") and the §6.5 "open question" are both factually wrong. This is a single-file documentation PR (`ai/testing-guidelines.md` +65 lines); no follow-up owed. **9 merged session PRs, not 8.**

2. **#91 v1-residue count is undercounted by a factor of ~3.** Plan claims "2 pin-point follow-ups" (run.sh ProviderConfig group + `describe.kind: PlatformSecret`) and calls the catch-block "API-group-agnostic". Verified the branch — additional residues in `tests/chainsaw/_lib/catch-block.yaml` AND in every scenario file (the block is pasted verbatim into 5 scenarios):
   - `for claim_kind in platformsecret platformcluster` — claim CRDs disappear in v2 (per SEG-1).
   - `kubectl describe "x${claim_kind}"` — depends on claim→XR resolution that v2 removes.
   - `kubectl get composite -o name` — `composite` category covers cluster-scoped v1 XRs; v2 namespaced XRs may not register under it (unverified, but likely a behaviour change).
   - `dump_diagnostics()` in `run.sh` references `platformsecret,xplatformsecret -A` and `crd/platformsecrets.platform.k8-platform.io` — same v1 claim/CRD assumption.
   
   Merging #91 as-is pastes the v1 idiom into **6 places** (lib + 5 scenarios) that SEG-4 then has to chase. The plan's premise ("amendments are mechanical and atomic enough to live in the SEG-4 PR") understates the surface.

3. **Pre-merge guard for #98 is fictional.** §4.2 says "confirm `_smoke`-only chainsaw filter is in place on `main`" before merging — no such filter exists on `main` today; this PR set never lands it. Either a real `CHAINSAW_SCENARIOS=_smoke` workflow edit is added to SEG-5 explicitly, or heavy CI flaps red between #98 and SEG-1 completion (exactly what the plan claims to avoid). Action item missing from §7.

4. **#94 close-vs-rebase math is contradicted by SEG-4.** SEG-5 §4.4 asserts all 6 goldens are unsalvageable. SEG-4 §1 table says only the **3 asm-secret** goldens need regen (UID-derived names, requires live chainsaw); the **3 external-secret** goldens carry deterministic `metadata.name` from `spec.claimRef.name` and are pure in-place edits (apiVersion + remove deletionPolicy + add `kind:` to providerConfigRef). Closing the PR throws away 3 perfectly-salvageable goldens and forces SEG-4 to re-author them from scratch. Prefer **rebase + partial rework**: keep #94 open, rebase onto post-#91 main, edit the 3 external-secret goldens in place, mark the 3 asm-secret goldens TODO pending live chainsaw.

## Completeness gaps

- **#86 (`wait-for-claim.sh`)** — plan marks "None functional". The script signature itself encodes the claim model; under v2's namespaced XR it may be obsolete (no claim → no `wait-for-claim`). Needs disposition: deprecate, rename to `wait-for-xr`, or keep as an alias?
- **#87 fixture `composition-missing-string-type.yaml`** — plan says 3 fixes. Also need `compositeTypeRef.apiVersion` bump (currently v1 group).
- **#93** — plan says repoint CRD URLs to v2.5.4; also need to verify Upbound's v2 packages still ship CRDs at the same path layout (`package/crds/*.yaml`) — not asserted, just assumed.

## Risky assumptions

- That GitHub's "auto-rebase #94 to main when #91 merges" applies even after #94 is closed (it does NOT — closing severs the auto-retarget).
- That cherry-picking 7 files out of a closed PR preserves authorship/history adequately for an autonomous-run audit trail.

## Report

Wrote `/home/user/k8-platform/ai/crossplane-v1-v2-un-fuckify/30-review-SEG-5-R1B-correctness.md`. Verdict REVISE-MAJOR. Top-2 flaws: (1) PR #96 is merged (testing-guidelines §10 doc PR), not a numbering gap — the §5 table and §6.5 open-Q are wrong and the merged-PR count is 9, not 8; (2) #91's v1 residues are undercounted — the catch-block.yaml itself loops over v1 claim kinds and uses `kubectl get composite`, so merging #91 pastes v1 idioms into 6 files (lib + 5 scenarios) that SEG-4 must then strip. Bonus: #94 close-decision contradicts SEG-4 (3 external-secret goldens are deterministic and salvageable in-place).
