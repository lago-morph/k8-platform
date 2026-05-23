# AGENTS.md suggestion: Adversarial subagent review whenever new tests are drafted

## Proposed addition

> **Adversarial subagent review of test plans.** Whenever any new
> tests are about to be drafted, or any existing test is about to be
> extended with a new assertion shape, spawn one or more subagents
> with an adversarial-reviewer brief before authoring the tests. The
> trigger is **source-agnostic** — it does not depend on who
> proposed the tests (user, agent, external review, copy-paste from
> another repo). It is a gate on the *act* of drafting tests, not on
> the source.
>
> Applies to: new phases, new components within a phase (new
> `helm_release`, IRSA role, XRD, ingress, IAM policy), standalone
> test additions in stable phases, extensions to existing tests that
> introduce a new assertion shape.
>
> Does NOT apply to: pure refactors, test file moves/renames,
> fixture updates that don't change assertion semantics.
>
> Default subagent type: `general-purpose`. Run two or more in
> parallel for substantial additions; one is acceptable for small
> standalone additions. Brief MUST include five sections: what
> ships, current test plan, known bug-class history (pasted from
> the bug-class registry), the verbatim job statement, declared
> non-goals. Adopt every adversarial suggestion unless declining
> with a one-line PR-description rationale per skipped item.
>
> *Grounded in: the 2026-05-23 phase-1 bring-up that hit seven
> distinct bug classes, each one in a contract the lead agent had
> not explicitly tested for.*

## Why this earns its place in your agents file

The cognitive failure mode is "test the contracts you already
thought of." Bugs hide in the contracts you didn't. The 2026-05-23
phase-1 bring-up surfaced seven distinct bug classes, each one in a
contract the lead agent had not added to the test plan; an
adversarial reviewer attacking the plan before the tests were
written would likely have caught at least four (helm chart key
spelling, IRSA-on-wrong-SA, missing helm_release for an existing
IRSA role, IAM action superset).

The cost is one subagent dispatch per test-drafting episode — a
~3-minute round trip in parallel with the lead agent doing other
work. The benefit is permanent: every test the adversary surfaces
catches a class of bugs that would otherwise reach a 15-minute
apply cycle.

Source-agnostic triggering is important because review-quality
falls off cliff if the discipline depends on who proposed the
tests. A user-proposed test list is not necessarily better than an
agent-proposed one; both benefit from adversarial attack.
