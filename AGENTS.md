# AGENTS.md — k8s-platform operating agreement

Canonical instructions for any AI agent in this repository (`CLAUDE.md` points
here). This file holds **judgment rules only** — preferences and methods.
Mechanical rules are **enforced by CI, hooks, and lints**, not memorized: if a
gate goes red, fix the cause; never weaken the gate. The reasoning and evidence
behind every rule, plus the protocol for changing them, live in
[`ai/LESSONS.md`](ai/LESSONS.md). The previous 748-line rulebook is archived
intact at [`docs/archive/agents-v1/`](docs/archive/agents-v1/) — historical
"§x.y" citations in scripts, tests, and retros resolve there.

**Budget: this file stays ≤150 lines.** Adding a rule requires the
`ai/LESSONS.md` §3 protocol (enforce mechanically first; prose is the last
resort) and, when full, removing a line.

## What this repo is

An **intentionally ephemeral** demonstration platform — the companion to a
planned blog series (`ai/blog/`), not a production cluster. The AWS account
rotates; rebuild-from-nothing is the *product*, not a tax. "Working" must be a
property of the repository, never of one hand-tended account. Every
account-specific value flows through discovery (variables, data sources,
outputs, the cluster-facts mechanism) — never through commits or hand-edits.

## Orientation (start of every session)

1. `scripts/whereami.sh` — establish the real account/state; treat the account
   as empty and `ai/handoff.md` as belief until the live API confirms.
2. `ai/handoff.md` — last verified state and the next concrete action.
3. `SUBSTRATE-READINESS.md` — the definition of done and what's still owed.
4. `docs/open-issues.md` — registered debt. `ai/environment.md` — sandbox
   capability profile (read before declaring anything unreachable/unavailable).

When work is scoped to a spec in `ai/specs/`, that spec is the sole design
authority; conflicts resolve toward the spec; ambiguity → ask, don't hybridize.

## The contract for "done" (outranks everything)

- "Done" / "fixed" / "works" / "proven" require **clean-build evidence**: the
  committed artifact produced the result from a build with zero manual steps
  (CI apply from committed source and/or GitOps sync), with the behavioral
  check passing **on that build**, recorded in `SUBSTRATE-READINESS.md` by run
  ID. Anything less is exactly **`pending clean-build verification`** — use
  those words.
- **Never mutate the live environment to make a check or feature pass** — no
  hand IAM policies, SG rules, tags, `kubectl apply`, overlay patches, or
  REST registrations as "fixes". Diagnostic *reads* are unrestricted. A live
  workaround proves a mechanism; it never validates the artifact, and counting
  it as progress is the project's documented core failure.
- **A red gate is real.** Fix the code or fix the check. Never re-kick to
  green, merge around it, or move a check somewhere non-gating (ADR-0009: a
  flaky check is itself the defect — make it deterministic or delete it).
- When a gate fails identically across content changes, stop changing
  content: re-run the last-green SHA (or equivalent) first to split
  environment from content (L32).
- Never weaken, skip, or disable error checking to clear an undiagnosed
  failure.

## Evidence and communication

- Label claim strength: **observation / exclusion / hypothesis / conclusion**.
  One data point that fits is "consistent with X", not "X is the cause".
- When CI fails, **read the failure log before theorizing** or reading
  anything else.
- Every undiagnosed failure either gets diagnosed this session or gets an
  entry in `docs/open-issues.md` (symptom, evidence, ruled-out, next step).
  No silent skips.
- `ai/handoff.md` carries verified facts (run IDs, SHAs, PR numbers), open
  work, and the next action — no narrative, speculation, or emotion.
- Artifacts a human will read follow the `human-scoped-deliverables` skill:
  plain-language lead, tables/small diagrams, IDs in a footer. Never commit a
  runnable-looking "next-session prompt" (enforced by lint; print it in chat).
- Crossplane v2 vocabulary: "XR" / "composite resource" — never "claim".

## Working with the owner

- Act on the answer to a question you asked; it overrides your prior plan.
- `[Request interrupted by user]` is a hard stop: no pivot to adjacent work;
  kill background processes; wait for direction.
- For large compound prompts (≥3 distinct actions or genuine ambiguity),
  confirm scope first — unless the owner signals "just go", which suspends
  only this repeat-back, never the done-contract or test discipline.
- Exhaust your own capabilities before asking (probe, install, read the
  output); ask only at genuine forks with cost or irreversibility.

## Test discipline

- Tests ship with the code: every feature PR carries its applicable layers
  (unit lint, kubeconform, render fixtures, chainsaw, live check); every bug
  fix starts with a test that reproduces it red at the closest layer, and the
  fix commits with that test.
- Behavioral verification coupled to the build is the oracle (ADR-0006);
  static checks are the floor. v2 CRD-boundary changes get a live-admission
  chainsaw pass before merge (ADR-0001).
- New enforcement checks scan **every** path where the bug class can occur,
  and land green in the same PR (audit-before-enforce).
- Heavy workflows stay `workflow_dispatch`-only; iterate to green against the
  SHA **before** opening the PR (the SHA-verifier gates it; finalize commits
  before dispatching, and never push to a gated branch while its dispatch is
  in flight — batch follow-ups; L33). CI wait mechanics: `ai/environment.md`.

## Git and phases

- Never commit to `main`. Branches: `feat/ fix/ chore/ test/ docs/`. Stacked
  PRs are affirmatively allowed (standing owner override) — base each child on
  the branch that last touched its files.
- One logical change per commit; imperative subject ≤72 chars; body says why.
  Never commit secrets, state files, or `terraform.tfvars`.
- Terraform: plan before apply; version pins change deliberately with reasons;
  both modules pass `terraform validate` before a PR is ready.
- "Tear down phase X" means exactly: (1) delete phase-X XRs and wait for
  deprovision; (2) delete phase-X XRDs/Compositions/manifests; (3)
  `terraform destroy` only the modules phase X added, reverse dependency
  order. It never touches lower phases, the management bootstrap, shared
  IRSA/IAM, or unrelated state. Broader teardown needs an explicit request.
- Never destroy a phase numerically lower than the one being worked on; after
  every state change update the Environment State block in `ai/handoff.md`.

## Subagents and planning

- Delegate delegable work; pick the fastest model that clears the quality bar.
- Before fanning out: verify every premise and framing against the repo
  (`grep`/`ls`) or the owner; brief reviewers and synthesizers to check
  load-bearing claims against the tree, naming the files. A false premise
  multiplies across every downstream agent.
- High-stakes plans get adversarial review by independent subagents.
- Overlap long provisioning waits with cluster-independent authoring/review.

## Domain loops (companion skills)

- Terraform push → `terraform-ci-watch`. Applied XR/XRD/Composition →
  `crossplane-claim-verify`; stuck XR → `scripts/crossplane-trace.sh`.
- Before any long CI dispatch the pre-dispatch audit runs (a PreToolUse hook
  blocks chainsaw dispatches that fail it).

## Current operating posture (owner-set, 2026-06-10)

Unattended/overnight volume runs are **paused** until the clean-build gate
(`SUBSTRATE-READINESS.md`) has been green twice. Until then: short, scoped
sessions with a machine-verifiable exit condition. The only feature backlog is
the four durable fixes + the from-scratch evidence loop (`ai/LESSONS.md` §5).
