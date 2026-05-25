# SPEC-TEMPLATE — how to author a spec

This template is the canonical shape for every `SPEC-*.md` file in this
directory. The existing 15 specs (SPEC-A1 … SPEC-C5) follow this shape
and are the gold-standard exemplars. Read **two or three** of them
before authoring a new one to absorb the prose style.

These documents are closer to **implementation plans** than to formal
specs: they include design rationale, file-by-file change lists with
absolute paths, concrete code/YAML fragments, retro-grounded
justification, and a verification checklist the implementing agent runs
at the end. They are written so a different agent can implement the
spec without asking the author follow-up questions.

Target length: **250–400 lines**. Shorter means too thin; longer means
the design hasn't been distilled. If your draft is much outside this
range, prune or expand sections before declaring it done.

---

## Required sections (in order)

### 1. Summary

One paragraph (4–8 sentences). State **what** is being added, **how** at
a high level, and **the smallest concrete artifact** that comes out
(e.g. "a single bash test file under `tests/unit/`", "a new Phase 6.0
block in the `crossplane-claim-verify` skill"). Reference cluster
membership if applicable (e.g. "part of `CLUSTERING-REVIEW.md` Cluster 2").

### 2. Retro pain killed

3–6 bullets, each citing a **specific** past failure this spec
prevents or diagnoses. Cite filenames and line numbers when possible
(e.g. `retrospective/2026-05-25-70.md` Phase 2, `ai/handoff.md:128`,
`PR #67`). Quote the relevant retro text when it is short. If a bullet
cannot point at a concrete past pain, drop the bullet — the spec gets
its priority from documented prior occurrences, not from speculation.

### 3. Out of scope

Bullet list of things this spec deliberately does NOT cover, with a one-
or two-sentence reason per bullet. Include a "Considered and rejected"
sub-section for design alternatives that were weighed and dropped (with
the reason for rejecting them — this is durable institutional memory).

### 4. Files to change / create

Either a table (Path | What changes) or two bulleted lists ("Modify" /
"Create"). **Use absolute paths starting at `/home/user/k8-platform/`**
so the implementing agent can copy-paste. List every file the
implementing agent will touch. If the spec asks for a new directory
layout (e.g. `tests/regression/<bug-id>/`), describe its shape here.

### 5. Implementation notes

The technical design. Subsections are normal. Include:

- Concrete syntax fragments (YAML, bash, HCL, regex) for any non-
  trivial new pattern.
- Output budgets (e.g. "≤5 KB per failure" with truncation rules).
- Retry / idempotency / failure-mode semantics.
- Cross-references to other specs whose patterns this one extends or
  consumes.
- Performance expectations (sub-second? <10s?).
- False-positive handling (for lints) or partial-failure handling (for
  diagnostics).

### 6. Tests required

The **must-have** tests without which this spec is incomplete. Use a
table (Layer | File | Assertion) or a numbered list. Reference
`AGENTS.md §6.1` (test-layer policy) and `AGENTS.md §6.4` (adversarial
review) when applicable. Specify the meta-test that proves the test
itself fires (e.g. a fixture that deliberately violates the rule, used
to prove the lint flags it).

### 7. Testing suggestions (unit / integration / e2e)

**This section is mandatory in every spec.** Three labeled sub-blocks:

- **Unit** — bash/script/lint-level tests. Fast (<10s each). Names
  follow `tests/unit/test_<name>.sh`. List 1–5 concrete cases with
  the assertion each makes.
- **Integration** — tests against a live cluster (kind for chainsaw,
  sandbox EKS for the deeper ones). Slower (seconds–minutes). Names
  follow `tests/integration/<NN>_<name>.sh`. List 1–5 cases.
- **E2E** — full-stack chainsaw scenarios or end-to-end probes
  exercised against a deployed phase-N cluster. Names follow
  `tests/chainsaw/<scenario>/chainsaw-test.yaml` or
  `tests/e2e/<name>/`. List 1–5 cases.

If a layer is genuinely **not applicable** (e.g. a documentation-only
spec has no integration or e2e surface), say so explicitly and explain
why — do not silently skip a layer. The next agent reading this spec
should know whether a missing layer was a deliberate scoping decision
or an oversight.

Distinguish from §6: §6 is the gate ("the spec is not done without
these"); §7 is the catalogue of follow-on tests one might add as the
surrounding system matures.

### 8. Documentation updates

Which canonical docs need a small edit: `AGENTS.md` (cite section),
`ai/testing-guidelines.md`, `ai/handoff.md`, `docs/operations.md`,
relevant `README.md`s, skill `SKILL.md` files. One short bullet per
doc.

### 9. Workflow / auto-invocation wiring

How the new thing gets invoked without anyone remembering to invoke
it: pre-commit hook, CI workflow auto-discovery, skill activation
phrase, chainsaw scenario default. Cite the workflow file or hook
path. If the spec is purely manual (a runbook), say so.

### 10. Discoverability

Three forcing functions, mirroring the style of SPEC-A4 §9 and
SPEC-B5 §9:

1. **Mechanical enforcement** — what fails (CI red, lint failure)
   when the rule is violated.
2. **Documentation pointer** — which AGENTS.md or guidelines line a
   future agent reads to land on this spec.
3. **Adversarial-review trigger** — what §6.4 review checklist item
   surfaces this concern.

### 11. Verification checklist

Bulleted `- [ ]` checklist of **concrete observable checks** the
implementing agent runs after coding the spec. Each item is a single
command + expected outcome (e.g. `yq '.spec.catch | length' file.yaml`
returns ≥ 3). 6–12 items is typical.

### 12. Rollout notes

- Backward-compat: does this break anything that worked before?
- Audit-before-merge: does the new test/lint require fixing existing
  files in the same PR (so the lint lands green)?
- Pluralsight sandbox constraints: us-east-1 / us-west-2 only,
  t2/t3/t3a/t4g micro/small/medium, ≤9 EC2 instances, no Bedrock /
  Marketplace. Most specs are orthogonal; say so if true.
- Coordination with in-flight branches.
- Branch sequencing per `CLUSTERING-REVIEW.md`.

### 13. Estimated effort

`S` (≤1 hr), `M` (1–3 hr), or `L` (>3 hr), with a one-paragraph
justification breaking the hours into authoring / rollout audit /
review-cycle / smoke-test components.

---

## Tone and prose conventions

- **No emojis** in spec files.
- **Cite retros, PRs, and AGENTS.md sections** rather than handwaving
  ("PR #67" beats "a recent silent-no-op bug").
- **Use absolute paths** for every file reference so a copy-paste run
  works.
- **State the trade-off, then the choice.** When you reject a design
  alternative, name it and give the one-line reason — that prevents
  the next session re-litigating the question.
- **Code fragments**: small, illustrative, well-commented. The
  implementing agent will type the final code; the spec gives the
  shape.
- **Don't claim the work is done.** Specs end at "the implementing
  agent runs the §11 checklist". They do not say "and then we ship".

---

## Common pitfalls in early drafts

- Section 2 too generic. If you cannot cite a specific past pain, the
  spec is speculative — re-evaluate whether it should land at all.
- Section 5 lists features instead of design. Each design decision
  should be justified (why this output format, why this regex, why
  this output budget).
- Section 7 (testing suggestions) reuses section 6 contents. They are
  distinct: §6 is the gate, §7 is the broader catalogue.
- Verification checklist (§11) is high-level. Each item should be a
  literal command the agent can run.
- Effort estimate (§13) ignores the rollout-audit cost. A lint that
  takes 30 min to write but 4 hours to audit and fix the repo is
  effort `M`, not `S`.
