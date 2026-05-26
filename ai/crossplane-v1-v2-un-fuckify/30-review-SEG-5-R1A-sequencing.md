# 30 — SEG-5 Review (Round 1, Reviewer A — sequencing angle)

**Verdict:** REVISE-MAJOR

## What the plan does well

- The #97 → #98 → #91 ordering is fundamentally right: a structural path-filter that unblocks main first, then the migration entry-point version bump, then a v1-agnostic enforcer.
- The "merge-then-amend" recommendation for #91 with explicit residue enumeration (run.sh L230 + describe.kind PlatformSecret) is concrete and reviewable, with three named options for the catch-block fix.
- The §5 enumeration of follow-ups for the 8 merged PRs is the most actionable artifact in the entire migration set — every patch owner is named, every owing segment cited.

## Sequencing flaws

1. **#98 → #91 ordering creates a guaranteed multi-day red main.** Plan acknowledges (§4.2) that #98 replaces `PendingExternalResource` with admission rejection on v1 manifests. After #98 merges, the unit tests `test_platform_{secret,cluster}_composition.sh` and `test_platform_{secret,cluster}_xrd.sh` (per 13-impact and SEG-3 §1) immediately go red on every push because they assert v1 group strings against still-v1 production manifests. SEG-3 picks "option (c) stacked PR on SEG-1" specifically to avoid this. SEG-5 must either (a) gate #98 behind SEG-1's stacked unit-test patch landing same-merge, or (b) explicitly disable those unit tests in a pre-#98 commit. The plan's "freeze chainsaw heavy-CI behind `_smoke` filter" addresses chainsaw but NOT the four unit tests that run on every push.

2. **#91 cannot be safely "merge-then-amend" if SEG-4's amendment slips.** Plan schedules #91 "Today+1" but SEG-4 §7 estimates the run.sh ProviderConfig group fix lands `after s4b` (chainsaw scenario rewrite), which itself blocks on SEG-1's `s1c` (ProviderConfig kind decision). That's a 5+ day window where main carries `apiVersion: aws.upbound.io/v1beta1` in `tests/chainsaw/run.sh` L230. With #98 already merged, every chainsaw dispatch goes red on the first `kubectl apply` of the ProviderConfig heredoc — not because of #91's catch block but because of the residue. **A stacked child PR on #91 carrying the two-line residue fix is the obviously-correct shape** and the plan dismisses it with a one-sentence wave about "rebase-conflict surface grows linearly." That's wrong: a stacked PR with two literal-string edits has near-zero conflict surface.

3. **#94 close-decision loses concrete value the salvage list undercounts.** §4.4 lists 6 enforcer scripts but the table at the top says "5 unit tests" — the count drifts. More critically, the plan says "cherry-pick the 7 salvage files onto the SEG-4 working branch immediately" but SEG-4's branch doesn't exist yet at the time #94 closes (SEG-4 §2.4 PR-T3 is on the #94 branch itself). The cherry-pick target is undefined. Fix: cherry-pick onto a NEW branch `claude/seg-4-c4-reauthor` created at #94-close time, with the 7 files committed verbatim; SEG-4 then opens PR-T3 from that branch. The plan needs to name this branch explicitly or the salvage will be lost in the handoff.

4. **§5 follow-up #93 (kubeconform fetcher) double-owned without sequencing.** Listed as "SEG-3 + SEG-4 (fixtures)." Both segments touch `scripts/fetch-crds-for-kubeconform.sh` and `kubeconform-schemas/**`. SEG-4 §2.4 PR-T1 explicitly regenerates the schema store; SEG-3 doesn't. The "SEG-3 + SEG-4" attribution is wrong — this is pure SEG-4. Misattribution risks SEG-3 author duplicating the regen and producing a conflicting PR.

5. **§5 follow-up #92 (crossplane-trace) overlaps with SEG-4 §2.2 "TraceFix."** Same file, same line (L215), same fix. SEG-5 attributes it to SEG-3; SEG-4's plan claims it as PR-T1 work ("Step 3a: crossplane-trace.sh L215 case-branch fix"). Duplicate ownership. Resolve: SEG-4 owns it (it ships with the schema-store regen that the script depends on).

6. **#96 numbering gap.** Closed-or-skip numbering is noise. `gh pr view 96` resolves it in 10 seconds. Mention as a one-line action ("verify with `gh pr view 96`"), not a §6 risk item. Currently inflates the risk register.

## Cross-segment hazards

- **#98 IRSA SA-pin verification gate is missing from SEG-5.** Plan defers to "SEG-2 verifies within 48h." But SEG-1 cannot start its drain step (SEG-1 §Step 0) until IRSA is verified. So #98-merge → SEG-2-verify → SEG-1-start is the real critical path, and SEG-5 should hold #91's merge until SEG-2 reports green — otherwise #91 lands on a main where the broken-IRSA blast radius is still unknown and the catch block's first real fire happens on a half-migrated cluster.
- **Two-PR concurrency on `tests/chainsaw/run.sh`.** §6 risk #4 names this correctly: #91 edits the file, SEG-4 also edits it. Plan asserts "#91 first means SEG-4 lands cleanly on top" — true only if SEG-4's edit doesn't touch the catch-block region (it doesn't; it touches L230). Acceptable, but worth a one-line note: "SEG-4 fixers must hold a pre-merge `git diff main -- tests/chainsaw/run.sh` to confirm no overlap with the merged #91 hunk."
- **#94 closure note must link to the new branch from flaw 3 above** or reviewers will not be able to find the salvage commits.

## Suggested concrete fixes

1. Gate #98 merge on SEG-1's unit-test patch being ready as a stacked PR (or pre-merge a no-op commit that skips the four unit tests with a TODO comment naming the SEG-1 PR that will re-enable them).
2. Restructure #91 as a 2-PR stack: parent #91 unchanged, child PR (new) carrying the two residue fixes, both reviewed in the same window, both merged together. Drop "merge-then-amend"; this is what stacked PRs are for (and the `stacked-pr-on-feature-branch` skill exists for exactly this).
3. Name the salvage branch `claude/seg-4-c4-reauthor`. Add a §5.5 "salvage manifest" listing all 7 files with their target paths on the new branch. Reconcile the "5 vs 6 vs 7" count discrepancy.
4. Reassign §5 #92 and #93 ownership entirely to SEG-4. Update SEG-3's plan to remove these from its scope (or accept the duplicate).
5. Add a "wait for SEG-2 IRSA verify" gate between #98 merge and #91 merge. Currently both are scheduled "Today / Today+1" with no IRSA-pin checkpoint between them.
6. Demote #96 from §6 risks to a one-line §7 action ("verify with `gh pr view 96`").
7. Add a "what makes main red and for how long" table showing, for each PR merge in the sequence, which CI jobs go red and what the recovery PR is. The plan currently shows the order without showing the CI-color timeline.
