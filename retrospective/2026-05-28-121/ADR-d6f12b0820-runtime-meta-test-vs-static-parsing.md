# ADR: Prefer runtime meta-test sanity checks over pre-commit static parsing for bash-script bug classes

- **ID**: ADR-d6f12b0820
- **Status**: Draft (not yet adopted to docs/adr/)
- **Date**: 2026-05-28
- **Source retrospective**: ../2026-05-28-121.md
- **PRs covered**: #111

## Context

PR #111's fourth chainsaw round surfaced a bug-class question we had not addressed before: the `_meta/composition-drift` scenario's premise was broken because it mutated a Composition base field that the Composition's `FromCompositeFieldPath` patch overrode. The mutation was a no-op; the test's sanity check correctly fired ("mutation did NOT propagate — meta-test is broken") and exited 1.

The natural follow-up question was: *can we catch this class of bug statically, at commit time, rather than letting a 5-minute cloud-CI round discover it?* Two implementation paths were considered. The user (the architect) chose the runtime path explicitly: "I'm good with the runtime test." The architectural question — which gating layer should defend against this bug class as a default — is broader than this one scenario and deserves a recorded decision so the next contributor doesn't litigate it again.

The runtime gate is the in-test sanity-check pattern: the meta-test mutates the Composition, then asserts the mutation propagated to the rendered MR before declaring the test mechanism healthy. If a future Composition edit adds a patch that overrides the mutated field, the sanity check fails. Zero new code; the gate is already in place for every scenario that follows the pattern.

The static gate would have required parsing the `yq -i '<path> = <value>'` invocations out of chainsaw `script.content:` blocks (regex against bash strings — fragile), parsing the matching Composition's `spec.pipeline[*].input.resources[*].patches[*].toFieldPath` list, and intersecting the two. Realistic implementation cost: ~120 lines of Python, plus a maintenance burden every time the chainsaw scenario shape evolves (multi-resource compositions, transform patches, kubectl-patch alternatives).

## Decision

When both a runtime meta-test sanity check and a pre-commit static parser can catch the same bug class, prefer the runtime check if the static parser requires fragile string-parsing of script content.

The default applies to bug classes that surface in chainsaw `script.content:` blocks, AI-generated bash scripts under `tests/integration/`, or other inline-bash-as-YAML constructs. It does NOT apply when the static check can operate on structured data (YAML keys, JSON paths, IAM policy actions, Helm values) — those classes are well-served by their existing static enforcers (`test_chainsaw_xr_conditions_complete.sh`, `test_kubeconform_manifests.sh`, `test_iam_required_actions.sh`).

## Alternatives considered

- **Static parser at pre-commit** — rejected. ~120 lines of fragile regex over bash string content. Fails on whitespace variation, line continuations, alternative mutation tools (kubectl patch, sed, jq), and multi-resource compositions. False positives nag the author; false negatives erode trust in the gate.
- **Skip the gate; rely on chainsaw CI discovering it** — rejected. The runtime gate already exists inside the meta-test's sanity check. Adding nothing leaves the gate in place but doesn't document the choice; a future contributor would re-litigate "do we want a static gate too?" without context.
- **Both gates — static AND runtime** — rejected. The marginal value of the static gate over the runtime gate is "catch the bug at commit time rather than chainsaw time", but chainsaw is already gated on this scenario via the workflow's path filter. Cost: ~120 lines of code to save ~5 minutes of CI per occurrence. The occurrence rate (this is the first instance in repo history) does not justify the investment.

## Consequences

**What becomes easier**: meta-test authors don't need to also author a pre-commit static parser for the same bug class. Adding a new meta-test scenario carries one cost (the runtime sanity check), not two. The pre-commit fast path stays uncluttered.

**What becomes harder**: catching this class of bug at commit time. The first observation of any new instance will be in chainsaw, not in `pre-commit run`. Authors must accept that the cost of a missed runtime gate is a chainsaw round (~5 minutes) rather than a pre-commit warning (~5 seconds).

**Trade-off accepted**: ~5 minutes of CI feedback latency per instance, in exchange for ~120 lines of code we don't maintain and a parser we don't have to evolve as the scenario format changes. The decision is reversible — if a third or fourth instance of this bug class lands, the cost-benefit shifts and a static gate becomes warranted; this ADR should be superseded at that point.

## References

- [`../2026-05-28-121.md`](../2026-05-28-121.md) — the source retrospective.
- [`./SKILL-SPEC-4b58a33e43-helper-wiring-audit.md`](./SKILL-SPEC-4b58a33e43-helper-wiring-audit.md) — companion spec; the wiring-audit skill identifies the static-vs-runtime gate question for every under-advertised helper.
- PR the decision was made in: #111.
- Related: AGENTS.md §6.13 (pre-dispatch static audit) — this ADR explicitly does NOT extend §6.13's coverage to the bash-script content parsing class.
