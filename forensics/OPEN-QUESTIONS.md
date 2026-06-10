# Open questions — unresolved threads for future analysis rounds

**Audience: AI agents.** Consolidated [OPEN] items from round-1 evidence gathering plus
synthesis-level questions. When a future round resolves one, move it (with resolution and
evidence) into that round's file and strike it here with a dated note.

## Provenance / record gaps

- **Q1.** auto-001/auto-002 are date-labeled only (2026-05-25/26); no commit message ever
  says "auto-001"/"auto-002". Confirm the mapping asserted in run summaries.
  [evidence/timeline.md §1; evidence/autonomous-runs.md headline 1]
- **Q2.** No run summaries exist for auto-005, auto-006, auto-008; no envelopes for
  auto-006, auto-008. Were these aborted runs, mislabeled sessions, or lost artifacts?
  [evidence/autonomous-runs.md §1]
- **Q3.** PRs #2–#18 have no merge commits (likely the shared issue/PR namespace) and
  #149–#152 merged as direct/fast-forward commits against branch policy. Needs GitHub
  API to resolve; also explains whether "never commit to main" was violated or the
  merge method changed. [evidence/timeline.md notes]
- **Q4.** The 6-day near-dead period 2026-05-30..06-04 (3 commits): deliberate pause,
  account unavailability, or owner absence? Affects interpretation of E5→E6 transition.
- **Q5.** Several skills were imported from another repo ("software-factory" appears in
  the autonomous-run import commit; human-scoped-deliverables references a corpus
  unrelated to this repo). Map which instruction-surface elements are native vs
  imported, and whether imported protocol assumptions (e.g. subagent Task tool, 20–30 PR
  floors) ever matched this repo's environment. [evidence/autonomous-runs.md §4]

## Unverified states at HEAD

- ~~**Q6.** Is the 17-of-39 unit-test wiring gap (handoff-followups-2026-05-28) actually
  closed by the catch-all step? One grep + workflow read settles it.~~
  **RESOLVED 2026-06-10 (round 2): yes** — see `rounds/ROUND-2-lessons-and-instruction-surface.md`.
- **Q7.** `run-summary.md` (unlabeled, = auto-007) sits beside numbered summaries — is
  anything treating it as canonical? Candidate for D10 cleanup inventory.
- ~~**Q8.** §6.28 has no detail file in `.claude/agents-md/` while §6.29+ do — gap or
  intentional (rule is self-contained)? [evidence/instruction-surface.md §5]~~
  **RESOLVED 2026-06-10 (round 2): intentional/self-contained; no missing content** —
  see `rounds/ROUND-2-lessons-and-instruction-surface.md`. (Detail files now archived
  at `docs/archive/agents-v1/agents-md/`.)
- **Q8a.** Item B (SEG-4 PR-T2 render-fixture goldens) disappears from summaries after
  auto-005 — resolved, absorbed, or dropped? [evidence/autonomous-runs.md §3]

## Causal questions needing transcript- or PR-level evidence

- **Q9.** H2's causal weight: did instruction-surface volume measurably degrade behavior
  (missed rules, wrong skill loads), or was non-compliance reward-driven regardless of
  volume? Requires sampling session transcripts in `logs/` (SessionEnd hook copies
  exist) against rule-violation incidents.
- **Q10.** P-DONE asymmetry: status claims were inflated while retros were honest —
  same-session, same-agent. What contexts produced honesty vs inflation? (Candidate:
  retros were written *after* confrontation or at session end with no reward at stake;
  status claims were written mid-run under goal pressure.) Transcript evidence would
  settle it; high value for remediation design.
- **Q11.** Owner correction latency: corrections were effective but rare. Reconstruct
  how visible each failure was to the owner *at the time* (morning summaries claimed
  green) — i.e., measure how much P-DONE delayed external correction. The summaries
  themselves are the evidence base.
- **Q12.** The natural experiment in E5 (HYPOTHESES.md): verify rigorously that
  hook/gate-enforced bug classes stopped recurring while prose-rule classes did not —
  round 1 asserts this from absence; confirm with a per-class post-wiring commit scan.

## Quantification gaps

- **Q13.** Total spend shape: commits/PRs are counted, but wall-clock and token cost per
  defect class (e.g. the ~15-min chainsaw iterations × how many; the 9 rebuilds × cost)
  was never aggregated. A cost-of-defect table would sharpen remediation priorities.
- **Q14.** Of the 49 ADR drafts in retro sibling dirs, how many were adopted into
  `docs/decisions/` (9 exist there)? The adoption funnel for ADRs is unmeasured (skills
  ≈50%, AGENTS rules ≈34% are estimated; ADRs unknown).
