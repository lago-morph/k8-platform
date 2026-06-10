# Round 2 — lessons substrate + instruction-surface restructure (2026-06-10)

**Scope set by the owner** (round-2 scoping, 2026-06-10): work from intent, not
the exact text, of the accreted agent instructions (overlaps/gaps/contradictions
acknowledged); automated enforcement wherever possible, agent instructions only
for preferences/methods; skills need the same treatment; **focus on turning the
project around now** while *collecting* material for the formal forward-looking
pieces (spec theory, document formats, portable discipline) to be built after we
see what works; primary deliverable = an **AI-optimized lessons document** that
future sessions use to keep optimizing agent behavior/performance, with a
human-facing companion.

## Deliverables produced

| Artifact | Role |
|---|---|
| `ai/LESSONS.md` | **Primary.** Lesson register (L1–L29) with enforcement states, the remedy-decision protocol (§3), instruction-surface budget, rule-by-rule disposition of AGENTS v1 (§4), structural backlog S1–S7 (§5), update protocol (§6), 2026-06-10 baseline (§7) |
| `docs/lessons.md` | Human-facing companion (per `human-scoped-deliverables`) |
| `AGENTS.md` (v2) | ~140-line operating agreement: judgment rules/preferences/methods only; ≤150-line budget |
| `ai/environment.md` | Single capability profile (closes D9's "no one place" gap) |
| `docs/archive/agents-v1/` | AGENTS v1 (748 lines) + 46 detail files, archived intact via `git mv`; historical §-citations resolve here |
| `.claude/skills-archive/` + README | 10 skills archived (admission rule LESSONS §3.2); 11 kept |
| `self-retrospective` amendment | AGENTS-MD rule files RETIRED as an output type; remedies now LESSONS-§3-classified |
| 3 new push-gated lints | `test_no_account_id_hardcoded.sh` (SPEC-B5, implemented from the existing spec), `test_no_next_session_prompt_files.sh`, `test_root_file_allowlist.sh` — wired into `tests/unit/run.sh` (CI catch-all auto-enrolls) |
| Rollout scrub | 26 pre-existing lint findings triaged (audit-before-enforce, SPEC-B5 §12): 18 noqa provenance markers (13 `ai/handoff.md`, 5 `docs/open-issues.md`); 1 noqa synthetic-constant marker (`test_live_evidence_gate.sh`); 3 findings removed by rewording account-derived literals out of forward-looking text (open-issues next-step command ×2, kyverno-lint comment ×1); 1 comment example generalized (`route53-record-live.sh`); 3 false positives (UUID tails in wait-for-claim fixtures) eliminated by the classifier's UUID handling |
| `docs/testing-debt-burndown.md` banner | D10 contradiction resolved: SUBSTRATE-READINESS supersedes; burndown is historical record |
| `ai/handoff.md` banner | Orients the next session on the new surface; auto-017 platform queue unchanged |
| `forensics/FORMALIZATION-COLLECTION.md` | Collection point for the deferred formal pieces + running worked/didn't log |

## Intent supersessions (deliberate, owner-direction-backed)

- **v1 §6.37** ("you have admin AWS — self-grant; never call the sandbox
  read-only"): the anti-false-premise half survives (`ai/environment.md` §2/§5);
  the *self-grant-and-mutate* half is **reversed** — diagnostic reads stay
  unrestricted, but mutating platform state to clear a blocker or pass a check
  is banned outright (AGENTS v2 done-contract). Grounds: the accountability
  retro's own remedy list; P-HANDFIX; owner-endorsed move 2 ("take the keys
  away", round 1). Durable form is structural S2.
- **v1 §8.6 / the autonomous-run volume protocol**: retired with the paused
  protocol (D7); revisit at S5.
- **v1 §6.5/§6.6 repeat-back machinery**: collapsed to one judgment line; the
  elaborate mode-switching added token load without evidence of effect.

## Open questions resolved this round

- **Q6** (is the 17-of-39 unit-test wiring gap closed by the catch-all?):
  **RESOLVED — yes.** `unit-tests.yml` header documents the `run.sh` catch-all
  as the completeness backstop (lines 17–20), and the catch-all is what
  auto-enrolls this round's new lints. Evidence: workflow file at HEAD.
- **Q8** (§6.28 has no detail file — gap or intentional?): **RESOLVED —
  intentional.** §6.28's full text is self-contained in AGENTS v1 (no "Full
  detail" link, unlike §6.29+). 46 detail files existed at archive time, not 47;
  the INDEX exhibit line was off by one. No content is missing.

Q7 (unlabeled `run-summary.md`) is *contained*, not resolved: the root lint
grandfathers it and blocks new root artifacts; relocation is S6.

## Verification

- All three new lints green repo-wide after the rollout scrub. The full local
  `tests/unit/run.sh` run shows 4 failing suites
  (`test_kubeconform_manifests`, `test_composition_render_*`) — verified
  **pre-existing and environment-caused** (kubeconform binary / render
  toolchain are installed by CI, absent in this sandbox): they fail
  identically on a clean stash of HEAD. The push-time CI run is the
  authoritative confirmation.
- No tooling referenced `.claude/agents-md/` or AGENTS v1 sections
  mechanically (grep audit: comment-only references in scripts/tests/
  workflows — all still resolve via the archive).

## What round 2 deliberately did NOT do

- Build S1–S4 (the from-scratch evidence loop, credential narrowing, the four
  durable seam fixes, PR triggers) — that is the next sessions' *platform*
  work, queued in `ai/handoff.md` (auto-017 order) and `ai/LESSONS.md` §5.
- Relocate the grandfathered root artifacts or the parallel `decisions/` tree
  (S6) — forensic exhibits stay put while analysis rounds may still cite them.
- Author the formal spec-theory/document-format deliverables — deferred by
  owner sequencing; collection file opened instead.
