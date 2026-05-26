# agent instruction

**Re-check environmental preconditions on each rotated account before diagnosing code failures.** "At session start AND when any CI failure shows infrastructure-level errors (`Unable to find remote state`, `AccessDenied`, 245s reconcile timeouts on real-AWS scenarios), verify: (1) `aws sts get-caller-identity` succeeds with the expected account; (2) the state bucket for phase 0 exists for the current account; (3) the GitHub Actions repo secrets match the current account. If any precondition fails, the in-repo handoff doc is stale per AGENTS.md §8.1 — DO NOT continue with code-hypothesis debugging."

*Grounded in: 2026-05-26 v1→v2 migration, terraform-test run 26436447517 wasted iteration on stale handoff before recognizing account rotation.*

# justification

testing-guidelines §10.1 already says verify environmental preconditions before code debug; this rule strengthens it with a session-start gate. The 2026-05-26 session dispatched `terraform-test phase=management apply-and-verify` based on the handoff doc's "phase 1 applied" line — and burned a fast-fail run (68s) before realizing the AWS account was rotated. By session-end, the same rotated-account state was suspected (correctly) of blocking the 3 platform-secret chainsaw scenarios. A 60-second session-start check (`aws sts get-caller-identity` + listing the state bucket) would have surfaced the rotation before any code dispatch. Cost of adopting: one `aws sts` call + one `aws s3 ls` per session start. Cost of NOT adopting: at least one fast-fail terraform dispatch and a chainsaw run that masquerades as the original v1-provider bug.
