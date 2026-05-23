# Spec: `adversarial-test-review`

## Intent

When an agent drafts a list of tests for a new phase or feature, the
default cognitive failure mode is to test the contracts the agent
*already thought of* while authoring the code. Bugs hide in the
contracts the agent *didn't* think of. The 2026-05-23 phase-1
bring-up made this concrete: seven distinct bug classes, each one
silent until the cycle that surfaced it, each one in a contract the
lead agent had not explicitly tested for (helm chart key spelling,
IAM action superset, ingress vs annotation interaction).

This skill addresses that failure mode by spawning subagents with an
adversarial-reviewer brief: their job is to attack the test plan,
not validate it. The lead agent then adopts their suggestions
wholesale, declining only with a one-line rationale per skipped
suggestion in the PR description.

The skill is invoked once per phase (or per meaningful expansion
within a phase) and produces a structured set of additional tests
to author.

## Trigger

**Direct user phrases:**

- "Review my test plan"
- "Run adversarial review"
- "What tests am I missing?"

**Proactive triggers:**

- Before starting test authoring for any phase ≥ 1 of the project.
- When `AGENTS.md §6.4` semantics apply: new phase, OR meaningful
  expansion (new XRD, new helm_release, new IRSA role).

**Negative triggers:**

- Pure refactors that don't change observable contracts.
- Test additions that themselves came from a prior adversarial review
  (no infinite loop).

## Inputs

A structured brief with five required sections (per `AGENTS.md §6.4`):

1. **What the phase ships** — bullet list of new files, resources,
   contracts. No prose.
2. **The current test plan** — list of tests the lead agent plans
   to write, with layer (unit / kyverno / integration / chainsaw) and
   the assertion shape for each.
3. **The known bug history** — paste of the bug-to-test traceability
   matrix from `ai/TESTING-PLAN.md`, plus any recent retros' bug-class
   findings.
4. **The job** — verbatim instruction. (See §6.4 for the canonical
   phrasing.)
5. **What to skip** — declared non-goals.

## Outputs

For each subagent dispatched, a structured response that the lead
agent can parse:

```
1. <Test name>
   Layer: <unit|kyverno|integration|chainsaw>
   File: <relative path>
   Assertion: <one sentence>
   Defends contract: <what this test would catch>

2. ...
```

Aim for 10+ concrete additions per subagent. Restate which contracts
each test defends so the lead agent can spot duplicates across
parallel subagents.

## Workflow

1. **Read AGENTS.md §6.4** to refresh the brief format. The brief
   template is normative — do not paraphrase it.
2. **Author the brief** by filling in the five required sections.
   Use real file paths, real contract names, real bug-class names
   from the latest retros.
3. **Decide subagent count.** Default: two `general-purpose`
   subagents in parallel for any phase that introduces new AWS
   provisioning or new XRDs; one subagent for smaller expansions.
4. **Dispatch in parallel** (single message with multiple Agent tool
   uses). Each subagent receives the same brief; they don't see each
   other's responses, so they converge independently.
5. **Aggregate responses.** Build a deduplicated table: test name →
   layer → file → assertion → contract. Two subagents proposing the
   same test is signal that the gap is real.
6. **Author the tests.** Implement every aggregated test that doesn't
   conflict with the declared non-goals. For any test you decline,
   add a one-line rationale to the PR description naming the test
   and why.
7. **Run the new tests** and confirm they pass against the new code
   (green). For any test that fails, follow `AGENTS.md §6.2` TDD
   discipline (the test caught something real; fix it).

## Concrete examples

### Example 1 — phase 2 XRD authoring (PlatformSecret)

Brief sketch:

- **Ships**: `crossplane/xrds/platform-secret.yaml`,
  `crossplane/compositions/platform-secret.yaml`, an ArgoCD
  Application that points at `crossplane/`.
- **Current plan (lead agent)**:
  - `tests/chainsaw/platform-secret/` Chainsaw scenario — apply XRD
    + Composition + Claim, assert composite Ready + k8s Secret
    materialized.
  - `tests/integration/04_eso_secret_round_trip.sh` already covers
    the underlying ESO flow; reuse.
- **Bug history**: paste bug rows 4, 5, 6 from `ai/TESTING-PLAN.md`
  (missing helm_release, wrong chart values, underscoped IAM).
- **Job**: verbatim from §6.4.
- **Skip**: AWS rate-limit testing.

Expected adversarial output (one of many possible):

1. **Composition patch coverage**: Chainsaw scenario should assert
   each patch in the Composition actually applies to the composite
   spec, not just that the composite reaches Ready. Catches: patch
   `fromFieldPath` typo that silently drops a value to the default.
   Layer: chainsaw. File: `tests/chainsaw/platform-secret/patches.yaml`.

2. **XRD schema rejection**: Apply a Claim with a required field
   missing and assert kube-apiserver rejects it at admission. Catches:
   `openAPIV3Schema.required` array drift.
   Layer: chainsaw. File: `tests/chainsaw/platform-secret/schema.yaml`.

3. **IRSA scope mismatch**: Kyverno policy that asserts every
   ClusterSecretStore using SA `external-secrets/external-secrets`
   refers to an IRSA role whose trust policy includes that
   `(namespace, sa)` pair. Catches: trust policy authored for the
   wrong SA name.
   Layer: kyverno. File: `policies/audit/09-eso-trust-policy.yaml`.

(Continues for 7+ more suggestions.)

### Example 2 — small expansion: adding cert-manager to phase 1

Brief:

- **Ships**: `helm_release.cert_manager`, `module.irsa_cert_manager`.
- **Current plan**: helm-render assertions + IRSA linkage tests.
- **Bug history**: bug 6 (`ListHostedZones`) is the closest analog —
  DNS01 challenge needs Route53 perms.
- **Job**: verbatim.
- **Skip**: ACME staging vs prod swap testing.

Adversarial output likely includes:

1. Integration test that issues a cert via Certificate CR, waits for
   `Ready=True`, asserts the secret materialized.
2. Kyverno policy: every Certificate must reference an existing
   ClusterIssuer.
3. Unit test: cert-manager IAM policy includes
   `route53:ChangeResourceRecordSets` scoped to the zone.

## Anti-patterns

- **Do not** invoke this skill on a session that's actively debugging
  a known bug. The TDD-on-bug-fix discipline (§6.2) is the right
  tool; adversarial review is for *planning* test coverage, not
  *responding to* a specific failure.
- **Do not** discard the subagents' outputs to "save time." Every
  declined suggestion goes in the PR description. The cost of
  documenting the decline is small; the cost of an undocumented gap
  is paid every time a future agent has to re-litigate it.
- **Do not** send the subagents partial briefs. All five sections
  are required for reproducible output.

## Acceptance criteria

1. Brief written in `AGENTS.md §6.4` shape (all five sections).
2. ≥ 2 subagents dispatched for a new phase; ≥ 1 for an expansion.
3. Subagent outputs aggregated into a table before any test code
   is written.
4. PR description includes "Adversarial review: <N> suggestions
   accepted, <M> declined (rationales below)."
5. The follow-up tests run green against the new code on the first
   try; any test that fails goes through §6.2 TDD discipline.

## Files this skill creates / modifies

- The PR being worked on — adds the aggregated tests across
  `tests/unit/`, `tests/integration/`, `tests/chainsaw/`,
  `policies/audit/` as appropriate.
- The PR description — lists adopted/declined suggestions.
- No persistent file under `.claude/` or `scripts/` — the skill's
  state is per-phase and lives in the PR.
