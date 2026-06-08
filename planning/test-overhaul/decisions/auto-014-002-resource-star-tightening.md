# auto-014-002 — Tightening `Resource:"*"` on the IAM/RDS provider role + deny tests

> Decision brief (autonomous-run protocol: two adversarial rounds, ≥3 real
> reviewers each). FINAL-PLAN §3.3 / §14.3 open owner choice.
> **Status: Round 1 — awaiting first adversarial wave.**

## Question

FINAL-PLAN §7/§14.3 contemplates tightening the Crossplane provider role's
`Resource:"*"` grants (on IAM and RDS especially) toward derived per-resource ARN
lists, and shipping **deny tests** (negatives that prove a now-forbidden action
is actually denied). The plan notes this is "real work, real blast radius on the
live provider role" and **recommends tightening** while leaving it an owner call.
Should auto-014 tighten `Resource:"*"` now (and ship the deny tests), or decline
(and drop the deny tests, documenting the gap)?

## Why it is genuinely owner-judgment

Narrowing the live provider role's resource scope can break provisioning in
non-obvious ways: Crossplane creates resources whose ARNs are not all known
ahead of time (auto-named RDS instances like `terraform-<rand>`, role names
templated per cluster). A too-tight policy silently fails reconciliation on the
*next* bring-up, not at apply time — a high-blast-radius, slow-to-surface failure
on the real platform.

## Alternatives

1. **Do NOT tighten now (my Round-1 call; the task's stated default).** Keep
   `Resource:"*"` on the provider role; document the gap in §14.3; do **not**
   ship deny tests that would assert a denial that isn't configured. Revisit when
   a derived-ARN inventory exists and a safe bring-up can validate it.
2. **Tighten incrementally + ship deny tests.** Narrow the least-risky verbs
   first (e.g. resource-types whose ARNs are fully derivable: OIDC providers by
   URL, cluster-scoped roles by templated name), ship a deny test per tightened
   verb, keep `*` where ARNs are non-deterministic.
3. **Tighten aggressively to derived lists + deny tests for all.** Maximal least
   privilege; highest risk of breaking the next bring-up.

## Round-1 decision (my best call)

**Do NOT tighten now (Alternative 1).** Per the task's explicit default ("default
to NOT tightening unless review is decisive") and AGENTS.md §6.35/§6.36: I cannot
run a clean bring-up from the sandbox to prove a tightened policy still
provisions, so tightening would be unverifiable and could silently break the next
real bring-up. A deny test for a denial that isn't actually configured would be a
test that "can't fire" — forbidden by FINAL-PLAN §7 ("a negative that can't fire
is not a test"). Record the gap; carry the tightening as a P4/P5 item gated on a
derived-ARN inventory + a teardown-and-rebuild validation window.

## Reasoning

The deny tests are only meaningful once the denial is real; the denial is only
safe once validated against a clean bring-up; that validation is unavailable
tonight. Declining is the reversible, fail-safe choice. The recommendation to
eventually tighten stands — this defers, it does not reject.

## Downstream impact

P5's negative tier ships WITHOUT the IAM/RDS `Resource:"*"` deny tests under this
call; the §14.3 gap is documented. If later adopted, the deny tests are added
alongside the policy narrowing, each with a red-first firing proof.

## Round-1 if-user-overrides rewind point

No code/infra change under the Round-1 call. If the owner chooses to tighten, it
lands as its own terraform PR + deny-test PR; revert that PR to restore `*`.
