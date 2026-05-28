# Open Issues — durable register of undiagnosed problems

Anything observed that we did not fully diagnose goes here. Per AGENTS.md
§6.14 ("Never ignore an undiagnosed failure"), an open issue is a
hard requirement — we record what happened, what we ruled out, and the
next concrete diagnostic step. The list shrinks as items get closed
(with evidence) and grows as new ones surface.

Each entry uses the format below. Identifier `OI-YYYY-MM-DD-N` where N
is the sequence number for that date.

---

## OI-2026-05-28-1 — `composition-drift` first-scenario timeout on chainsaw

**Status:** open
**Surfaced:** 2026-05-28, PR #125 chainsaw dispatch (run id `26552671925`,
HEAD SHA `b31cc87`).
**Symptom:** `composition-drift` scenario times out at 245s on the
"wait for XR Ready" step. XR shows `Synced=True`, `Ready=False
(reason=Creating, message="Unready resources: asm-secret")`,
`Responsive=True`. The same XR shape on the same composition, applied
seconds later by `claim-creates-secret`, becomes Ready in ~8 seconds
and provisions an ASM secret successfully (verified via the in-test
`aws secretsmanager describe-secret` call).
**Diagnostic evidence available so far:**
- Same XRD + Composition + provider config across all scenarios.
- Subsequent scenarios in the same run (`claim-creates-secret`,
  `claim-rotation`) provision AWS Secrets Manager secrets without
  delay or error.
- AWS CLI calls in later scenarios authenticate and succeed against
  the new test account, so the GHA secrets are valid.
- The current `tests/chainsaw/_lib/catch-block.yaml` was looking in
  `$NAMESPACE` (chainsaw scratch namespace) while test XRs live in
  `default`, so the catch output was diagnostically empty — fixed in
  the same PR that registered this issue. Future occurrences will
  surface the MR's own status conditions.
**Hypotheses (UNCONFIRMED — no positive evidence either way):**
- AWS-provider / function-extra-resources / kind-cluster CNI cold
  start on first MR reconcile, exceeding 245s on the new account but
  not on warm subsequent reconciles.
- Transient flake (one-shot AWS API hiccup, image pull, etc.).
- New-account-specific IAM permission lag (e.g., a freshly-issued
  access key takes time to propagate through AWS's auth caches).
**Ruled out:**
- Stale credentials (`§8.2`): later scenarios on the same run
  authenticate and create AWS secrets successfully.
- Regression from this stack's Task 2 changes: `git diff main
  chore/audit-wiring-fixes-2026-05-02 -- crossplane/ tests/chainsaw/`
  is empty. The Task 2 diff is in `.claude/`, `scripts/`,
  `.github/workflows/`, `tests/integration/`, `tests/unit/` only.
**Next diagnostic step:** the (a) re-dispatch against the same SHA
`b31cc87`, run `26553305708`, is in flight; outcome will narrow the
hypothesis space.
- If `composition-drift` fails identically → deterministic; investigate
  provider-side cold-start (provider logs, kind CNI warm-up, function
  pull) or new-account IAM propagation.
- If it passes on retry → transient flake; downgrade urgency, raise
  the chainsaw assert-timeout for the first scenario or warm the
  provider before the first MR.
**Owner / next action:** awaiting re-dispatch outcome (ETA ~04:06Z
2026-05-28).

---

<!-- New entries go above this line, newest first. -->
