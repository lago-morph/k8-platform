# Formalization collection — material for the future formal, forward-looking pieces

**Audience: AI agents (and the owner at review time).** The owner's direction
(2026-06-10, round-2 scoping): *focus on turning the project around now, while
collecting what we need to do the more formal, forward-looking pieces after we
can see what works and what doesn't.* This file is that collection point.

**The deferred deliverables this collects for** (do not build them yet):

1. **A theory of the spec** — what a spec must pin down to avoid the pitfalls
   this project's record documents, derived from evidence rather than generic
   best practice.
2. **A complete spec for this platform** — written to that theory (the
   ephemerality contract as one section).
3. **Reusable spec/process discipline** — rules for doing this consistently in
   future projects.
4. **Strict document formats** — templates for consistent, portable documents
   across the owner's projects.

**Formalize only after** the clean-build gate (`SUBSTRATE-READINESS.md`) has
been green twice (owner's sequencing): the turnaround is the experiment whose
results these pieces must encode.

**Collection protocol:** during turnaround sessions, append dated entries to §5
("worked" / "didn't work" / "candidate"), each with an evidence pointer. Keep
entries terse; this is raw material, not the deliverable.

---

## 1. Spec-theory candidates (from the forensic record)

- **Boundary contracts (the D1 lesson).** Every layer handoff is specified as:
  named artifact, producer, consumer, lifecycle, and verification step. A
  sentence of the form "then X takes over" is a detectable spec defect — all
  four standing blockers trace to exactly such sentences. (Evidence:
  `evidence/spec-and-structure.md` §2; REPORT D1.)
- **Value-lifecycle classification (the D6 lesson).** Every value the system
  consumes is classified at spec time: committed constant / derived at build /
  discovered at runtime / secret. For ephemeral substrates, "discovered at
  runtime" must dominate, and any committed account-derived value is a spec
  violation (mechanically lintable — SPEC-B5 proved the pattern).
- **Version pinning as a spec section (the D2 lesson).** Every external moving
  part (provider, chart, controller, API version) gets an explicit pin + an
  upgrade trigger. The unpinned Crossplane provider cost ~4 project-days.
- **Verification co-specified with function (the D4/D5 lesson).** Each spec
  section names its acceptance evidence (which gate, which check, what counts
  as proof) — "done" semantics are part of the spec, not of the agent's mood.
- **Vocabulary lock (the D3 lesson).** A spec declares its terms (e.g.
  "phase" vs "Iteration"; "XR" vs "claim") and successor docs may not fork
  them silently.

## 2. Document-format candidates (observed working here)

- **Evidence-tagged corpus** (`forensics/` conventions): [FACT]/[INFERENCE]/
  [OPEN] tags, append-only evidence files with dated CORRECTION lines,
  synthesis rewritable, stable IDs (D/P/R/L/S). Worked well; portable.
- **Gate-with-evidence-column** (`SUBSTRATE-READINESS.md`): definition of done
  + enumerated anti-evidence (what does NOT count) + owner-auditable run-ID
  column. The single best "done"-semantics format in the record.
- **Open-issues register** (`docs/open-issues.md` format): status index +
  per-issue symptom/evidence/ruled-out/next-step with OI-date-N IDs.
- **Handoff banner discipline** (`ai/handoff.md`): newest-first superseding
  banners; facts + run IDs + next action only. Failure mode to design out:
  stale lower sections contradicting the banner (D10) — candidate format rule:
  superseded blocks get struck or moved to an archive section, not stacked.
- **Operating agreement + lessons-substrate + environment-profile triple**
  (round 2's `AGENTS.md` / `ai/LESSONS.md` / `ai/environment.md` split):
  judgment rules vs evidence/protocol vs facts. Portability hypothesis to test
  during the turnaround.
- **Anti-format (negative evidence):** per-rule instruction fragments assembled
  into an ever-growing rulebook (152 candidates → 51 rules → no behavior
  change). Do not port.

## 3. Instruction-discipline candidates

- The remedy-decision protocol (`ai/LESSONS.md` §3): mechanical check > one
  budgeted prose line > structural change > observation. Plus the budget
  (≤150-line agent file; skill admission rule §3.2).
- Skill taxonomy that earned its keep: environment bridges / domain loops /
  owner-valued interfaces. Everything else archives.
- Hooks that **block** (PreToolUse exit-2) outperformed every advisory
  mechanism in the record.

## 4. Open questions the turnaround must answer before formalizing

- Does the 150-line operating agreement actually hold behavior where 748
  lines didn't, once the structural pieces (S1/S2) exist? (This is H2/H5
  disentanglement, live.)
- Is the lessons-file update loop (`ai/LESSONS.md` §6) actually exercised by
  future sessions, or does it rot like `docs/iterations/` did?
- Which of the document formats in §2 survive contact with a non-platform
  project? (Portability is asserted, not proven.)
- What's the right owner-visibility surface so corrections come earlier
  (forensics Q11 — morning summaries hid the red)?

## 5. Running log (append during turnaround sessions)

| Date | Worked / Didn't / Candidate | Observation | Evidence |
|---|---|---|---|
| 2026-06-10 | candidate | Round-2 restructure executed (this PR); all §1–§3 entries above are candidates pending turnaround evidence | forensics rounds 1–2 |
