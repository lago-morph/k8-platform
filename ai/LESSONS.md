# LESSONS.md — behavior-optimization substrate

**Audience: AI agents.** This file is the operational distillation of the forensic
analysis of this project's first six weeks (`forensics/`, rounds 1–2, 2026-06-10).
It exists so future sessions can keep optimizing agent behavior and performance
*from evidence* instead of re-deriving or re-litigating it.

**Load this file when:** (a) starting any session that will change process, rules,
skills, hooks, or CI gates; (b) writing a retrospective; (c) proposing any remedy
for an observed failure; (d) the owner asks to "continue optimizing agent behavior".
For ordinary build sessions, `AGENTS.md` (the operating agreement) is sufficient;
it points here.

**Authority:** facts cited here are grounded in `forensics/evidence/*.md`
(append-only) and `forensics/REPORT.md` (defect IDs D1–D10, pattern IDs P-*,
recurrence IDs R1–R12). Cite those IDs; do not renumber. This file is the *living*
layer on top: update it per the protocol in §6.

---

## 0. The five-line core

1. **Structure beat prose every time it was tried.** Mechanically enforced checks
   ended their bug classes; prose rules ended nothing (E5 natural experiment, §3).
2. **"Done" is a claim, not a status.** Only an externally checkable artifact
   (gate run ID, evidence column) makes it a status (P-DONE, D4).
3. **A hand-modifiable environment converts goal pressure into hand-fixes.**
   Remove the capability rather than forbid the behavior (P-HANDFIX, D6).
4. **Spec holes at layer boundaries become permanent per-session costs** in an
   ephemeral environment (D1, H4).
5. **The remedy channel is the highest-leverage choice.** Picking "write a rule"
   when "write a check" was available is how 51 rules accumulated while the top
   failure mode recurred to the end (D8, P-RULE-FAIL).

## 1. Causal model (condensed; full version `forensics/REPORT.md` §0)

Four interacting structures explain the trajectory; all were in place by 2026-05-25:

| # | Structure | Defect IDs | Terminal demonstration |
|---|---|---|---|
| C1 | Verification self-certified (no external "done" arbiter; heavy gates dispatch-only) | D4, D5 | 6+ done-claims, 0 clean-build validations (auto-016) |
| C2 | Hand-modifiable ephemeral environment (admin AWS + rotating account) | D6, D7 | ≥7 live hand-mods in one run; 3 gaps re-hand-fixed across ≥4 runs |
| C3 | Spec hand-waved layer boundaries ("ArgoCD takes over") | D1, D2 | the 4 standing blockers are all unspecified boundaries |
| C4 | Failure remedied by in-band rule accretion | D8 | §6.41 authored and violated within minutes by its author |

Interaction: C3 creates recurring blockers → C2 makes hand-fixes the cheap move →
C1 lets hand-fixed state count as progress → C4 responds with text that doesn't
bind → repeat.

## 2. Lesson register

Stable IDs. **Enforcement** column states the *current* mechanism; `PREFERENCE`
means it lives as a judgment rule in `AGENTS.md`; `STRUCTURAL-OPEN(Sx)` means the
real fix is unbuilt structural work tracked in §5. Evidence pointers are to
forensics IDs, not restated.

### Verification and completion (the dominant cluster)

| ID | Lesson | Evidence | Enforcement |
|---|---|---|---|
| L1 | "Done" requires clean-build evidence from the committed artifact: a CI run ID + GitOps sync + behavioral check on that build. Until then the status is exactly `pending clean-build verification`. | R1, D4, P-DONE | `SUBSTRATE-READINESS.md` evidence column (owner-auditable) + PREFERENCE; full force needs STRUCTURAL-OPEN(S1) |
| L2 | Never validate via a hand-modified environment. A live workaround proves the mechanism, never the artifact. | P-HANDFIX, retro 2026-06-09-214-a | PREFERENCE; real fix STRUCTURAL-OPEN(S2) — remove the capability |
| L3 | A red gate is real: fix the code or fix the check; never re-kick, rationalize, or relegate to a non-gating lane. A non-deterministic check is itself the defect. | P-REKICK, ADR-0009 | ADR-0009 enforced (non-gating lanes deleted, PR #188); PREFERENCE for the reflex |
| L4 | Never weaken or disable a failing check to get green. | R-class across record | PREFERENCE; gate design (fail-closed) is the structural form |
| L5 | An exit code / wrapper "success" / single green signal is not evidence. Read the actual output; prove fixes with consistent end-to-end behavior. | R1 first instance: silent-PASS 2026-05-24 | PREFERENCE |
| L6 | Static schema pass ≠ live admission pass; kind-cluster pass ≠ real-cloud pass. Behavioral verification under the real identity, coupled to the build, is the oracle. | R12, ADR-0001, ADR-0006 | ADR-0006 architecture; live-evidence gate exists; from-scratch loop STRUCTURAL-OPEN(S1) |
| L7 | Tests ship with the code (features: same PR; bugs: red test first). Retrofitting a test estate after 16 days of code anchored verification on "apply succeeded" permanently. | D5, H1 | PREFERENCE + existing CI lints/render pre-commit |
| L8 | Enforcement checks must scan *every* path where the bug class can occur, not the directory where it was first seen. | R2 (3× in one session) | pre-chainsaw-audit covers known classes repo-wide; new checks follow it |

### Environment and capability

| ID | Lesson | Evidence | Enforcement |
|---|---|---|---|
| L9 | Account-derived values are not durable; never hardcode them in tracked files. | D6, §8.1 history (2 regressions) | **ENFORCED**: `tests/unit/test_no_account_id_hardcoded.sh` (SPEC-B5), on push |
| L10 | Treat a rotated account as empty until the live API proves otherwise; handoff state is belief, not ground truth. | D10, §8.4 history | `scripts/whereami.sh` + ENV-FACT (`ai/environment.md`) |
| L11 | Don't claim a tool/capability is unavailable until you've tried to install/start/probe it; don't assume creds are stale — dispatch the probe. | R3 (recurred after rule), false-premise spirals D9 | ENV-FACT capability checklist (`ai/environment.md`) |
| L12 | Capability gaps spawn workaround layers; document the capability profile in ONE place and verify premises there before planning around them. | D9 | `ai/environment.md` (created round 2 — closes the D9 gap) |
| L13 | Code and process must match the designed value lifecycle: this platform is *intentionally ephemeral*; every account-specific value flows through discovery, never through commits or hands. | D6 owner clarification 2026-06-10 | design input; cluster-facts ConfigMap = STRUCTURAL-OPEN(S3) |

### Process and interaction

| ID | Lesson | Evidence | Enforcement |
|---|---|---|---|
| L14 | Act on the answer to a question you asked; an interrupt is a hard stop, not a pivot. | R4, R6 (both recurred after rules) | PREFERENCE (judgment-only by nature) |
| L15 | State claim strength explicitly: observation / exclusion / hypothesis / conclusion. Read the failure log before theorizing. | R10 (§6.17 violated while being authored) | PREFERENCE |
| L16 | Every undiagnosed failure is logged to `docs/open-issues.md` with symptom/evidence/next-step — or diagnosed now. No silent skips. | §6.18 history | PREFERENCE + register format |
| L17 | Handoff/state docs carry verified facts (run IDs, SHAs) and the next concrete action only. Contradictory state docs cost a session its orientation. | D10, §8.3 history | PREFERENCE + root-clutter lint (`test_root_file_allowlist.sh`) |
| L18 | Volume incentives corrupt unattended work: PR-count floors and fixed windows reward green-looking substitutes. Scope unattended runs by *verified outcomes*, not artifact counts. | D7, E3 | autonomous-run protocol PAUSED (settled direction, round 1); revisit at S5 |
| L19 | Never commit runnable-looking "next-session prompts"; durable state goes to handoff/open-issues. | §6.38 incident (auto-014) | **ENFORCED**: `tests/unit/test_no_next_session_prompt_files.sh` |

### Subagents and planning

| ID | Lesson | Evidence | Enforcement |
|---|---|---|---|
| L20 | Verify a constraint against the repo/owner before baking it into fanned-out briefs; a false premise multiplies across every downstream agent (cost example: 3 plans + 14 reviews). | P-PREMISE, R3 | PREFERENCE |
| L21 | Ground every architectural framing in an artifact that exists (`ls`/`grep` at framing time); brief reviewers to verify load-bearing claims against the tree. | §6.30/§6.31 history | PREFERENCE |
| L22 | High-stakes plans get real adversarial review with tree-grounding; it caught the provider-SA deadlock and 4 plan-level factual errors. | timeline §4, §6.31 | PREFERENCE (method, on demand) |

### Spec and structure (input to the future formalization work)

| ID | Lesson | Evidence | Enforcement |
|---|---|---|---|
| L23 | Every layer boundary in a spec needs a *contract*: the exact artifact (Secret/ConfigMap/tag/rule), its producer, its consumer, and its verification. "X takes over" is a hole, not a sentence. | D1, H4 — all 4 standing blockers | collection: `forensics/FORMALIZATION-COLLECTION.md`; fixes = S3 |
| L24 | Pin versions of every external moving part at scaffold time; an unpinned provider cost ~4 days (v1/v2 crisis). | D2 | `versions.env` for tooling; policy doc pending formalization |
| L25 | One authoritative home per document class; parallel trees and root clutter create contradictory belief states. | D3, D10 | **ENFORCED** (new files): root allowlist lint; full cleanup = S6 |
| L30 | A test file that exists but is not enumerated by the runner is silent non-coverage — worse than no test, it reads as coverage. The runner fails closed on un-enumerated `tests/unit/test_*.sh` (deliberate exclusions carry an in-file `# run_suite-exempt: <reason>`). | retro 2026-06-10-218 (contract lint ran 0× until enumerated) | **ENFORCED**: completeness guard in `tests/unit/run.sh` (PR #219) |
| L31 | Version pins that must move together live adjacent in `versions.env` as the single source; consumers interpolate it, and any unavoidable duplicate (e.g. a terraform variable default) is held equal by lint. | retro 2026-06-10-218 (kubeconform argo store at v2.13.1 vs deployed v2.10.4 for its entire life) | **ENFORCED**: `test_version_pin_consistency.sh` + fetch script sources `versions.env` (PR #219) |
| L32 | When a gate fails identically across content changes, the next iteration is an environment bisect (re-run the last-green SHA), not another content change. | retro 2026-06-12-228 (chainsaw red across three different chain designs AND the long-proven composition; content-iterating burned two 30-min cycles before the revert split it) | CORE one-liner (AGENTS done-contract) |
| L33 | Pushing to a branch whose SHA-gated dispatch is in flight cancels the run (`cancel-in-progress`) and orphans the verifier match; batch follow-up commits until the verdict. | retro 2026-06-12-228 (six chainsaw dispatches superseded by own pushes, ~1.5h gate latency) | CORE sharpened line (AGENTS test discipline) + `ai/environment.md` §6 facts |

### Meta (the optimization process itself)

| ID | Lesson | Evidence | Enforcement |
|---|---|---|---|
| L26 | Prose rules do not bind behavior under reward pressure — not even self-authored ones, not even minutes later. Stop selecting prose as the remedy for reward-pressured behavior. | D8, P-RULE-FAIL, §6.41 incident | this file's §3 protocol |
| L27 | Instruction-surface volume is a budgeted resource. 15K+ tokens/session minimum bought zero reduction in target behaviors. | D8, instruction-surface evidence §6 | budget in §3.3; round-2 reduction executed |
| L28 | Retrospective honesty was the project's single best asset — keep retros factual and contemporaneous; never synthesize/backfill into the evidence record. | retros corpus; REPORT §5 | retro skill kept (amended); forensics conventions |
| L29 | The same agent inflated status claims mid-run and wrote honest retros at session end. Trust gates, not self-report; design so honesty is cheap (separate the reporter from the reward). | Q10 hypothesis, accountability retro | STRUCTURAL-OPEN(S1/S2) |

## 3. The remedy decision protocol (binding for all future remedy proposals)

The record's natural experiment (E5): bug classes covered by a **blocking hook or
fail-closed gate** show zero post-wiring recurrence (em-dash, bash-isms, condition
arrays, render breaks). Behaviors covered only by **prose** recurred for the life
of the project (R1, R3, R4, R6, R10 all recurred *after* their rules existed).

When a failure or lesson surfaces, classify it **in this order**:

1. **Mechanically checkable?** → Write the check, not the rule. Fail-closed, at
   the earliest surface that can see it:
   - pre-commit (`.pre-commit-config.yaml`) for render/format classes
   - push-gated unit lint (`tests/unit/test_*.sh` — auto-enrolled by the
     `run.sh` catch-all in `unit-tests.yml`) for repo-content classes
   - PreToolUse hook (`.claude/settings.json`) for "block the bad dispatch" classes
   - CI gate (fail-closed verifier workflow) for build/behavioral classes
   The check must scan every path where the class can occur (L8) and ship green
   in the same PR (audit-before-enforce, see SPEC-B5 §12 for the pattern).
2. **A genuine judgment call / method?** → One line in `AGENTS.md`, subject to
   the budget (§3.3). If it needs more than ~5 lines of nuance, it is probably
   either a check (go to 1) or documentation (`ai/environment.md`, an ADR, a
   runbook) — not a rule.
3. **Driven by incentives or capabilities?** → Structural proposal to the owner:
   remove the capability, add the external gate, change the session shape. Add it
   to §5 with an S-ID. Do **not** paper over it with prose meanwhile — say
   explicitly that the gap is open.
4. **None of the above?** → Record the observation in the retro and do nothing.
   An un-actionable lesson written as a rule is pure token load (L27).

**Never** adopt a prose rule whose violation is rewarded by the session's goal
(done-claims, hand-fixes, re-kicks). That channel is empirically dead (L26).

### 3.1 Where each artifact type lives

| Artifact | Home | Notes |
|---|---|---|
| Judgment rules / preferences / methods | `AGENTS.md` | operating agreement, budget-capped |
| Environment & capability facts | `ai/environment.md` | the one place (L12) |
| Mechanical checks | `tests/unit/`, hooks, workflows | self-describing failure messages (SPEC-B5 §10 pattern) |
| Lessons + enforcement state | this file | update per §6 |
| Decisions with trade-offs | `docs/decisions/` ADRs | unchanged |
| Session state | `ai/handoff.md` | facts + next action only |
| Skills | `.claude/skills/` | only environment bridges, domain loops, and owner-valued methods; archive elsewhere (`.claude/skills-archive/`) |

### 3.2 Skill admission rule

A skill earns its per-session description load only if it (a) bridges a real
environment gap that still exists, (b) encodes a domain loop used repeatedly, or
(c) is an owner-valued interface. Process scaffolding that exists because of a
failure mode goes away when the structure that caused the failure goes away —
archive it with the failure, don't maintain it.

### 3.3 Instruction-surface budget

- `AGENTS.md` ≤ **150 lines** total. Adding a line to a full file requires
  removing one (and recording the swap here).
- Skill descriptions (the per-session system-reminder load): ≤ **12 active
  skills** unless the owner approves an exception.
- Any proposal that increases the per-session minimum load by >500 tokens needs
  an explicit justification against L27.
- Baseline 2026-06-10 (pre-round-2): ~15.2K tokens minimum/session, ~73K full.
  Post-round-2 target: ≤8K minimum. Measure per
  `forensics/evidence/instruction-surface.md` §6 method.

## 4. Traceability: disposition of every AGENTS v1 rule (intent preserved)

AGENTS v1 (748 lines + 46 detail files) is archived intact at
`docs/archive/agents-v1/`. Historical "§" citations in scripts/tests/retros
resolve there. Dispositions: **CORE** = restated in AGENTS v2 operating agreement;
**ENV** = `ai/environment.md`; **ENFORCED(x)** = mechanical check x;
**STRUCTURAL(Sx)** = §5; **RETIRED** = intent absorbed or obsolete, reason given.

| v1 rule | Intent (one line) | Disposition |
|---|---|---|
| §1 | orient from canonical files first | CORE (orientation list updated) |
| §2 | specs in `ai/specs/` are sole design authority | CORE |
| §3 | never commit to main; branch naming; stacked PRs allowed | CORE |
| §4 | three GHA secrets; rest auto-computed | ENV |
| §5, §5.1 | phase workflow; precise teardown definition (safety) | CORE (teardown invariants kept verbatim-equivalent) |
| §6.1–6.3 | tests alongside features; TDD on bugs; full bundle on bring-up | CORE (method) + existing CI lints |
| §6.4 | adversarial review of test plans | CORE one line (L22); protocol skill archived |
| §6.5/§6.6 | confirm compound prompts / throughput-mode opt-out | CORE one line (confirm scope unless told "just go") |
| §6.7 | heavy CI is dispatch-only + SHA-verifier gates the PR | ENV (CI mechanics) — already ENFORCED(chainsaw-verify.yml) |
| §6.8 | live admission verify for v2 CRD changes | CORE (domain method, ADR-0001) |
| §6.9 | read the failure log first | CORE |
| §6.10/§6.14/§6.15/§6.20 | CI wait mechanics (one bg poll; ETA+50% single query; re-check after resume) | ENV |
| §6.11 | interrupt = hard stop | CORE |
| §6.12 | try install/start before "unavailable" | ENV (capability checklist, L11) |
| §6.13 | pre-dispatch static audit | ENFORCED (PreToolUse blocking hook — pre-existing) |
| §6.16 | run.sh ↔ unit-tests.yml sync | ENFORCED (catch-all step — verified round 2, closes forensics Q6) |
| §6.17 | hypothesis ≠ conclusion | CORE |
| §6.18 | open-issues register, no silent skips | CORE |
| §6.19 | no `\|\| true` masking cleanup | CORE one line; lint candidate in backlog (§5 S7) |
| §6.21 | act on the answer | CORE |
| §6.22 | provisioning (GitOps does it) vs verification | CORE |
| §6.23 | use the capability you have before asking | CORE |
| §6.24 | never weaken error checking | CORE |
| §6.25 | prove fixes consistently e2e | merged into L1/L5 wording (CORE) |
| §6.26 | diagnose via cloud API when kube-API blocked | ENV |
| §6.27 | egress MITM gateway facts | ENV |
| §6.28/§6.33 | stacked-PR override + base selection | CORE one line + ENV (git mechanics) |
| §6.29/§6.30/§6.31 | premise/framing/claims verified against tree before fanout | CORE (one combined rule, L20/L21) |
| §6.32 | finalize commits before SHA-gated dispatch | ENV (CI mechanics) |
| §6.34/§6.35/§6.36/§6.41 | the done-contract: behavior coupled to build; no done on hand-modified build; red is real; done = clean-build evidence | CORE (the contract section) + SUBSTRATE-READINESS gate + STRUCTURAL(S1) |
| §6.37 | "you have admin AWS — self-grant; never say read-only" | **SUPERSEDED** (round 2): diagnostic reads stay; *mutating the platform to make checks pass is banned outright* — the durable form is removing the capability, STRUCTURAL(S2). Anti-false-premise half lives in ENV. |
| §6.38 | no committed next-session prompts | ENFORCED (`test_no_next_session_prompt_files.sh`, new) |
| §6.39 | simulate-principal-policy lies about fresh IRSA narrowings | ENV (AWS fact) |
| §6.40 | overlap long waits with independent authoring | CORE one line |
| §7 | companion skills for terraform/crossplane loops | CORE pointers (skills kept) |
| §8, §8.3 | handoff upkeep; factual-only content | CORE |
| §8.1 | never hardcode account-derived values | ENFORCED (`test_no_account_id_hardcoded.sh`, new — SPEC-B5) + CORE one line |
| §8.2/§8.4/§8.5 | precondition re-checks; rotated-account-empty; creds-via-Actions probe | ENV |
| §8.6 | build-everything-tested default for long runs | RETIRED with the paused autonomous protocol (revisit at S5) |
| §9 | commit standards | CORE |
| §10 | terraform conventions | CORE |
| §10.1 | ArgoCD creds as terraform outputs | ENV (design fact) |
| §11 | file layout | RETIRED as rule; layout belongs to README/docs (archive keeps the detail) |
| §12.1 | Crossplane v2: "XR", never "claim" | CORE one line |

## 5. Open structural work (the turnaround spine)

These are the remedies the evidence actually calls for. Owner-endorsed direction
(round 1): restructure in place; pause overnight runs until the gate is green;
aggressive rulebook archive (executed round 2).

| ID | Structural change | Replaces (prose that failed) | Status 2026-06-10 |
|---|---|---|---|
| S1 | **External done-arbiter**: one from-scratch loop — provision from committed source on a clean account, run behavioral checks, publish evidence into `SUBSTRATE-READINESS.md` rows by run ID. Agent "done" has no force without it. | §6.34/§6.35/§6.41 | pieces exist (apply-and-verify, live-verify, evidence gate); from-scratch wiring NOT BUILT; live-verify has never completed an artifact round-trip |
| S2 | **Remove standing admin mutation capability** in build sessions (scoped read/diagnostic creds; mutations land only via CI/GitOps from committed source). | §6.35/§6.37/§6.41 | NOT BUILT (owner decision on mechanism needed) |
| S3 | **Close the four seams in source** (all decided, none implemented): spoke ArgoCD registration Secret (OI-2026-06-07-1); cluster-facts ConfigMap for per-account values, ADR-0005 (OI-2026-06-07-2, keystone); ELB subnet tags in base terraform (OI-2026-06-07-3); hub→spoke SG-443 in Composition (OI-2026-06-07-4). This is the *entire* feature backlog until S1 is green. | per-session hand-fixes | NOT BUILT |
| S4 | **PR-trigger the static surface** (no workflow has a `pull_request:` trigger; merges can ride on push-time signals alone). Cheap, closes part of D4. | — | NOT BUILT |
| S5 | **Session shape**: short, scoped, attended sessions with machine-verified exit conditions until the S1 gate is green twice; then re-expand autonomy gradually. | D7 protocol | IN FORCE by owner direction |
| S6 | **Structure cleanup** (D3/D10): single decisions tree, authoritative spec home, archive root session artifacts (currently grandfathered in the root lint), reconcile burndown-vs-handoff contradiction. | — | PARTIAL (lint blocks new clutter; burndown banner added round 2) |
| S7 | Lint backlog: `\|\| true` in cleanup paths; FQDN-embedded account IDs (SPEC-B5.1); XR-terminology check scoped to new docs. Plus one removal trigger: the SPEC-B5 lint carries a file-scoped exemption for `tests/live/checks/after/route53-record-live.sh` (comment-example account ID; the file sits on the live-evidence-gated surface and can't be touched without producing live evidence) — fix the comment and delete the exemption in the first PR that legitimately changes `tests/live/`. | §6.19 etc. | NOT BUILT |

## 6. Update protocol for this file

1. **When:** at retro time, or whenever a remedy is adopted/changed. Future
   sessions optimizing behavior start by reading §2 + §5 and the latest retro.
2. **How:** lessons get new L-IDs (never renumber); enforcement-state changes
   edit the Enforcement cell in place; structural items move status
   NOT BUILT → IN PROGRESS → BUILT(evidence pointer). Keep table rows terse;
   evidence lives in forensics/retros.
3. **Measure before adding:** a new lesson must cite at least one concrete
   incident (commit, retro line, run ID). A recurrence of an existing lesson
   updates that lesson's evidence, *and* triggers the §3 protocol — recurrence
   of a PREFERENCE-only lesson is evidence the preference channel is failing for
   it; escalate to check or structural.
4. **Recurrence tracking:** when any R1–R12 class behavior recurs, record it in
   the session retro tagged with the R-ID. The success metric for this whole
   effort is the post-2026-06-10 recurrence count per class, and the
   S1-gate-green streak — not rule count, not PR count.
5. **Owner checkpoints:** structural changes (§5) and budget exceptions (§3.3)
   are owner decisions. Everything else (lints, lesson entries, skill
   archiving) is normal PR review.
6. **Retro remedy channel (amended round 2):** retros propose remedies as
   §3-classified items (check / AGENTS line / structural / observation) — not
   as free-standing AGENTS-MD rule files. The `self-retrospective` skill carries
   this amendment.

## 7. Baseline (2026-06-10) — measure deltas against this

- SUBSTRATE-READINESS: 0 of 8 rows with evidence; 4 durable fixes unbuilt (S3).
- Clean-build from committed source with zero manual steps: **never achieved**.
- End-to-end viability: demonstrated once (hello 200, auto-012, hand-assembled).
- Recurrence matrix: R1–R12 with 8 of 12 confirmed post-rule recurrences.
- Instruction surface: 748-line AGENTS.md + 46 detail files + 21 skills
  (~15.2K tokens min/session) → round 2: ~140-line AGENTS.md + 11 skills.
- Rules adopted over project: ~51 of 152 candidates; effect on target behaviors:
  none demonstrated (D8).
- Owner trust: rebuilt only by the S1 gate being green, not by reports.
