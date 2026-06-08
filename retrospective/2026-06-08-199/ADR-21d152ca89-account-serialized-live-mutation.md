# ADR: Account-serialized live mutation via a DynamoDB lease and a deny-list reaper

- **ID**: ADR-21d152ca89
- **Status**: Draft (not yet adopted to docs/decisions/)
- **Date**: 2026-06-08
- **Source retrospective**: ../2026-06-08-199.md
- **PRs covered**: #197, #198

## Context

The live test suite is moving toward default-on MUTATION (FINAL-PLAN P4/P5: an
instantiate tier that creates real cloud resources, and a reaper that deletes
leaked ones). Two runs on the same AWS account — or a run and the reaper — that
mutate concurrently can corrupt each other: the reaper could delete a resource a
live run is mid-flight on, or two runs could collide on shared singletons. Before
any default-on mutation lands, the suite needs (a) a way to serialize mutating
runs per account, and (b) a reaper whose destruction is provably safe. auto-014
built both as pure, testable libraries (the live deletes/creates are wired later).

## Decision

Serialize destructive/mutating live-suite runs per AWS account with a
DynamoDB-lease account mutex, and gate the reaper behind a fail-safe structural
deny-list plus run-id/age/lease guards.

The mutex is a single DynamoDB row keyed on the account id, holding the current
`run_id` and `lease_expires`. Acquire is a compare-and-set `put-item` with a
ConditionExpression — succeed iff there is no holder OR the holder's lease has
expired — so a dead/suspended holder is stolen atomically while a live holder
blocks. The reaper reaps a candidate ONLY when every guard passes, in precedence:
(1) a structural deny-list of protected platform singletons — matched as a
deny-list, not an allow-match, so a mislabeled protected resource is still safe;
(2) it must carry a `live-verify` run-id tag; (3) it must not be the current run;
(4) its run-id must not hold an active lease; (5) it must be older than an
age-floor that is strictly greater than the mutex lease-TTL (45m > 30m), so a
just-created resource from a concurrent run is never reaped.

## Alternatives considered

- **Hub-mutex / kube-lease instead of account-mutex.** Rejected: resources are
  account-scoped (IAM, RDS, ACM), so a per-cluster lock does not prevent two runs
  on the same account from colliding. The lock must be keyed on the account.
- **Reaper allow-list (only delete what matches a known pattern).** Rejected as
  the primary guard: an allow-match fails OPEN if a protected resource is
  mislabeled or a pattern is too broad. A structural DENY-list of protected ids
  fails SAFE — an unrecognized resource is simply not reaped.
- **Read-then-write lock (GET then PUT).** Rejected: races. A DynamoDB
  ConditionExpression makes acquire/steal a single atomic compare-and-set.
- **SSM Parameter Store backing.** Viable, but DynamoDB conditional writes give
  cleaner compare-and-set semantics; the scoped role already enumerates the table.

## Consequences

- Easier: P4/P5 can mutate safely; the reaper can run first without friendly fire;
  the safety logic is unit-tested in isolation before any live delete is wired.
- Harder: a run now depends on a DynamoDB table and must renew its lease before
  the TTL during long operations; a suspended run beyond the TTL must re-acquire
  before trusting prior resources.
- Accepted trade-off: the lease-TTL/age-floor relationship (TTL < age-floor) is a
  tuned invariant that must hold — encoded in code and asserted by the unit test.
- Defence in depth: the IAM policy ALSO tag-conditions every reaper delete, so a
  logic bug in the selection lib still cannot delete an untagged resource.

## References

- [`../2026-06-08-199.md`](../2026-06-08-199.md) — the source retrospective.
- `tests/live/lib/account-mutex.sh`, `tests/live/lib/reaper-select.sh` — the libs.
- `tests/unit/test_account_mutex.sh` (16/0), `tests/unit/test_reaper_select.sh` (11/0).
- `terraform/management/verifier_role.tf` — the lock table + the zero-wildcard policy.
- PRs: #197 (mutex), #198 (reaper-select). FINAL-PLAN §8, §14.8.
