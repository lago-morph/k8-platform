# ADR: AWS test account identifiers are ephemeral and must never be hardcoded in repo artifacts

- **ID**: ADR-bc50754311
- **Status**: Draft (not yet adopted to docs/adr/) — the rule itself has been merged into `AGENTS.md` §8.1 via PR #69; this ADR captures the architectural reasoning.
- **Date**: 2026-05-25
- **Source retrospective**: ../2026-05-25-70.md
- **PRs covered**: #69

## Context

The AWS account underneath the test environment is rotated between sessions; the prior account is typically torn down in full before the next session starts. Account ID, derived FQDNs, IRSA role ARNs, EKS cluster endpoint, OIDC provider ARN, ACM cert ARNs, Cognito pool IDs — every account-scoped identifier — does not survive a session.

The first version of the handoff doc written in this session hardcoded the late-2026-05-24 account ID (`413117505476`) in approximately twelve places: Environment State table, Phase states table, Live AWS resources block, ArgoCD URL, S3 backend bucket name, ACM SAN. The user flagged this directly: *"The account is ephemeral, and is deleted in full usually between sessions. So it is very much not a durable identifier, and treating it as such will just confuse the next agent."*

Cost evidence: the next session would read the handoff, see specific resource identifiers, attempt to query / verify them, fail (because they don't exist on the new account), and waste a debug loop discovering "wait, those resources are gone" before realizing the doc lied. The cost compounds because the next agent may then mis-correlate the staleness with their own bug rather than with handoff drift.

The session merged a one-paragraph rule into `AGENTS.md` §8.1 (PR #69) codifying this. This ADR captures the architectural reasoning behind the rule so future contributors understand *why* the rule exists, not just *what* it says.

## Decision

The AWS test account underneath the management environment is **architecturally ephemeral**: every account-scoped identifier must be queried via `aws sts get-caller-identity` (or other live `aws` CLI calls) at session start and never hardcoded into plans, handoffs, code comments, Terraform, scripts, or workflow YAML.

Concretely:

- **Forbidden in repo artifacts**: account ID; derived FQDNs (`<account-id>.realhandsonlabs.net`); IRSA role ARNs; EKS cluster endpoint or OIDC provider ARN; ACM cert ARNs; Cognito pool IDs; ASM secret ARNs.
- **Allowed**: cluster names (fixed by `variables.tf`), resource shapes ("the crossplane IRSA role"), abstract patterns ("`<account-id>.realhandsonlabs.net`"), durable audit-trail artifacts (run URLs, PR / commit SHAs).
- **Required at session start**: `aws sts get-caller-identity` to confirm the active account, before any operation that depends on account context.

## Alternatives considered

**(a) Pin the test account so identifiers are durable.** Rejected by the test environment's design — the account rotation is a policy of the cloud lab, not a configurable agent behavior. Even if the policy changed, hardcoded IDs would still rot when the lab eventually rotates.

**(b) Maintain a separate "current account" pointer file (e.g. `.account-id`) and let docs reference it.** Considered, but rejected because the pointer file would itself be stale between sessions, defeating the purpose. The live `aws sts get-caller-identity` is always current and requires no file maintenance.

**(c) Strip account-derived identifiers via a pre-commit hook.** Adds value as defense in depth but doesn't substitute for the rule — a hook would need to know which identifiers are account-derived, which requires the same intent the rule provides. Captured as a pending follow-up (item in §8.1 mentions defense-in-depth tooling).

## Consequences

**Easier:**

- The next session can resume from any handoff without first auditing it for staleness.
- Generalizes beyond AWS accounts: any per-session identifier (sandbox FS paths, run IDs as something-to-trust, ephemeral SHAs as workload state) follows the same rule.
- The handoff doc becomes durable across multiple sessions — it captures behavioral intent ("phase 2 is half-fixed in PR #68") not transient values ("the cluster endpoint is `https://A1B2...gr7...`").

**Harder:**

- Authoring a handoff requires one extra step per identifier: "is this thing account-scoped?" If yes, write it abstractly.
- Reviewers need to know the rule to catch violations at PR time.

**Accepted trade-off:**

- The handoff is slightly less concrete (no clickable URLs for the resources) in exchange for being correct after the account rotates.

## References

- [`../2026-05-25-70.md`](../2026-05-25-70.md) — source retrospective; the rule's grounding.
- [`./AGENTS-MD-…`](./) — no per-rule file for §8.1 itself (it was merged directly via PR #69; reprocess can backfill if desired).
- PR #69 — merged the rule into `AGENTS.md` §8.1.
- `AGENTS.md` §8.1 — the canonical rule.
