# ADR: Validate a live-policy tightening on a real CREATE path behind a sentinel-gated draft PR

- **ID**: ADR-79a955b122
- **Status**: Draft (not yet adopted to docs/adr/)
- **Date**: 2026-06-08
- **Source retrospective**: ../2026-06-08-207.md
- **PRs covered**: #203

## Context

auto-015 had to act on OI-2026-06-08-1: tighten the Crossplane provider role's IAM
`Resource:"*"` to derived prefixes (`role/k8-platform-*`, `oidc-provider/*`). The prior
run (auto-014-002) deferred this *solely* because there was no clean bring-up to validate
against — a too-tight policy fails silently on the *next* reconcile, not at apply time, so
it cannot be shipped unverified (§6.35). auto-015 had a real bring-up, but two sharp
problems surfaced during the work, each from a real adversarial-review finding or a live
observation: (a) the narrowed IAM path is exercised *only* by the spoke's
Crossplane-created roles/OIDC — the hub roles are Terraform-created — so a hub-only apply
validates nothing; and (b) the obvious "prove the denial" mechanism,
`aws iam simulate-principal-policy`, returns `implicitDeny` for *every* action on a
freshly-modified IRSA role, so it cannot serve as the firing proof. A third problem is
structural: the policy is applied to the live account *from a branch* before the PR
merges, so a "do not merge" note in the PR body is an unenforceable hope.

## Decision

A live-policy-mutating change is validated by driving the real controller to CREATE, under
the narrowed policy, a resource the policy must permit (not by a permission simulator), and
its PR is held as a draft behind a failing sentinel-gate check until that CREATE-path
validation is observed, at which point the sentinel, the open-issue RESOLVED flip, and the
handoff record land in one atomic commit.

## Alternatives considered

- **Permission simulator as the firing proof** (`iam:SimulatePrincipalPolicy`). Rejected:
  on a just-modified IRSA role it returns `implicitDeny` for everything — even
  unambiguously-allowed `Resource:"*"` actions — so it cannot distinguish allow from deny.
  Kept only as an optional always-on check that SKIPs when its positive control is denied.
- **Static source lint alone** (assert the narrowed Resource strings in the terraform).
  Rejected as *sole* proof: it confirms the source says X, never that the live policy
  permits the real creates — exactly the "manifest says X" gap the test overhaul exists to
  kill. Kept as a cheap regression guard alongside the CREATE-path proof.
- **Hub-only apply as the validation.** Rejected: the hub's IAM roles are Terraform-created
  under operator creds, so a hub bring-up exercises zero of the narrowed controller-driven
  `iam:CreateRole`/`CreateOpenIDConnectProvider` calls. Only the spoke's Crossplane-created
  identity resources test the narrowing.
- **Prose "HELD — do not merge" in the PR body.** Rejected: unenforceable in a bottom-up
  merge stack; a reviewer merges a green-looking PR by reflex. Replaced with a draft PR +
  a failing required sentinel-gate check.

## Consequences

- **Easier:** a live-policy tightening can be landed during an autonomous run with a real,
  authoritative validation (the real IAM engine, on a real create), and the merge cannot
  happen ahead of that validation. The open-issue state, the merge-readiness, and the
  durable evidence stay consistent because they land in one commit.
- **Harder / accepted trade-offs:** the change is applied to the live account from a branch
  before merge, so there is a window where the live policy is narrower than `main` — this
  run accepted that as safe because the broad policy is the safe superset (a future apply
  from `main` reverts it) and the narrowing was proven non-breaking. The pattern needs a
  provision that exercises the narrowed path (here, the spoke-access CREATE), so a tightening
  whose path nothing provisions this run stays deferred (e.g. RDS/EC2 were filed as
  follow-ups gated on their provisions).
- A small standing cost: a per-change sentinel file + a ~30-line gate test, and discipline
  to clear them atomically with the issue/handoff updates.

## References

- [`../2026-06-08-207.md`](../2026-06-08-207.md) — the source retrospective.
- [`./SKILL-SPEC-c171288fe9-live-policy-create-path-validation.md`](./SKILL-SPEC-c171288fe9-live-policy-create-path-validation.md) — the reusable procedure.
- `planning/test-overhaul/decisions/auto-015-001-iam-resource-tightening-clean-build.md` — the 2-round decision brief.
- PRs: #203 (the IAM narrowing, validated on the spoke CREATE path).
