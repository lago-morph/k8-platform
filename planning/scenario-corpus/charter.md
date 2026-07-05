# Project charter — k8s-platform-scenarios

**What this is:** the founding charter for a separate repository,
`k8s-platform-scenarios`. It is written to be that repository's first commit.
Until the repository exists it lives here, in the platform repo's planning
area, as a reviewable draft. Everything a scenario-writing session needs is in
this one document — by design, since such sessions must not see the platform
repository at all.

---

## Mission

Find defects by using the platform the way its real users would, and by
comparing what the *documentation* promises with what the *product* does.

The platform's "workload" is people doing jobs: **owners** maintain and
enhance the core; **tenants** develop and deploy applications on it; an
**author** writes the companion blog series from it. Scenarios are those jobs,
written down, matured into executable tests, and run against real builds.

Every scenario is simultaneously a test of four artifacts. When one fails,
the finding names which:

| Defect lives in | Signal |
|---|---|
| **Documentation** | The scenario cannot be written, or written steps don't match reality |
| **Implementation** | Documented steps executed faithfully produce the wrong outcome |
| **Requirements** | Steps work as documented, but the abstract architecture intended something else |
| **The scenario itself** | Its assumption was wrong; fix the scenario, record why |

## The docs-blindness contract (the founding rule)

Scenarios are developed **exclusively** from:

1. The platform's published documentation site (user-facing, diataxis-structured).
2. This charter.
3. Credentials and endpoints provided for the role being exercised.

Scenario authors — human or agent — must never read the platform
repository's source. If a scenario cannot be built because the documentation
lacks the information, **that is the finding**: file it as a documentation
bug, leave the scenario blocked-on-docs, move on. Working around a docs gap
by peeking at implementation destroys the corpus's entire diagnostic value.

The one nuance: the platform's *own manifests for user-claimable resources*
(e.g. "apply this YAML to claim a database") are public surface **as
documented** — if the docs show the YAML, the scenario may use it; if the
docs don't, that's a docs bug, not an invitation to go find the schema in
the source.

## Maturity pipeline

Every scenario is at exactly one level; levels advance deliberately.

| Level | Form | Bar to advance |
|---|---|---|
| **L0 — bullet** | One sentence: role + verb + surface, plus a one-line objective | Someone decides it's worth describing |
| **L1 — scenario** | Actor, preconditions, prose steps, observable outcome, defect classes it would catch | The steps can be written from the docs alone |
| **L2 — executable spec** | Concrete commands/manifests, a machine-checkable oracle, cleanup, isolation, cost class | A person or agent can run it from the doc with role credentials only |
| **L3 — automated test** | Runs unattended; PASS/FAIL by exit code; bounded polls (never bare sleeps); idempotent cleanup; order-independent | Flake-free enough to trust |
| **L4 — gating** | Runs on every platform clean build; failure blocks "done" | Proven record at L3 |

Determinism bar (L3+): fixed inputs; oracles are assertions, not judgment;
every wait is a bounded poll with an explicit budget; cleanup runs on both
success and failure and is re-entrant; scenarios never depend on each other's
state; anything destructive or costly is opt-in via an explicit mode flag,
off by default.

## The generative taxonomy

New scenarios are cells in a matrix — append L0 bullets freely, prioritize
maturation deliberately:

- **Roles:** platform owner · tenant admin · tenant developer · engineer
  end-user (kubectl via directory group) · author (blog series) ·
  adversary (things that must *fail*)
- **Verbs:** onboard/add · deploy/use · change/upgrade · observe/debug ·
  rotate/secure · offboard/remove · break/recover · explain/demonstrate
- **Surfaces:** clusters · identity · secrets · databases · ingress/DNS/TLS ·
  GitOps delivery · observability · policy/guardrails

Author-role scenarios get one extra rule: their demos may *show* concepts
from the published docs/blog, but every demo step still *executes* through
public surfaces only, and each published post's demo script keeps running
against future builds — a published post whose demo breaks is a finding.

## Execution contract (every L2+ scenario carries)

- **Actor + credential source**: how the test authenticates *as that role*.
  If there is no documented way to obtain the role's credentials, that is
  itself a product/docs finding.
- **Preconditions**: required platform state, stated as observables.
- **Steps**: from the docs; cite the doc page each step came from.
- **Oracle**: the deterministic assertion(s) that define PASS.
- **Cleanup**: how the scenario removes what it created.
- **Isolation**: naming/namespacing so parallel runs don't collide.
- **Cost/destructiveness class**: free-read · cheap-create · costly-create ·
  destructive (destructive never runs by default).
- **Time budget**: the bound on every poll, and on the whole scenario.

## Findings

A finding is a structured record: scenario id · what was attempted · what
the docs said · what happened · which of the four artifacts the defect lives
in (or "undetermined") · evidence (output, run id). Findings flow back to the
platform repository as issues; this repository never fixes the platform, the
docs, or the requirements itself.

## Growth and governance

- Anyone (human or agent session) may append L0 bullets — cheap by design.
- Maturation L1→L4 is prioritized by risk and by what the platform can
  currently execute (see the seed backlog's wave ranking).
- A scenario blocked-on-docs stays visibly blocked; the count of
  blocked-on-docs scenarios is the documentation quality metric.
- This charter changes by PR with the platform owner's review.

## Relationship to the platform repository

The platform repository (`k8s-platform`) owns: the implementation, the
requirements, and the **documentation source** (published to the docs site
this repository consumes). It carries a standing requirement that the
documentation be sufficient to author scenarios without implementation
visibility. This repository owns: scenarios, their harness, and findings.
The two meet only at (a) the published docs site and (b) findings filed as
issues.

## Seed backlog

The initial L0 catalog (ranked by the order scenarios can realistically be
*executed*, which tracks platform capability; describing them at L1 has no
ordering constraint) is maintained in this repository once bootstrapped.
The founding version was drafted alongside this charter.
