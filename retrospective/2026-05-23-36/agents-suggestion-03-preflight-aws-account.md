# AGENTS.md suggestion: Preflight check before apply-and-verify

## Proposed addition

> **§7.1 Preflight before any apply-and-verify dispatch.** Before
> dispatching `terraform-test.yml` with `action=apply-and-verify`
> on any phase, the agent runs `scripts/preflight-aws-account.sh`
> (or equivalent — STS check + Route53 zone presence + EC2 quota
> headroom). If the script exits non-zero, the agent does not
> dispatch; it escalates to the user with the script's output.
>
> The preflight runs once per session, or whenever AWS credentials
> are known to have rotated. It does not run on `plan` /
> `verify-only` dispatches.
>
> *Grounded in: the 2026-05-23 phase-1 rerun, which failed mid-job
> at "Discover Route53 zone" because the AWS account had been
> rotated to one without a pre-existing public hosted zone. ~10
> minutes lost to dispatch + diagnose.*

## Why this earns its place in your agents file

The CI workflow correctly aborted with a clear message — there was
nothing in the code to fix — but the failure surfaced 90 seconds
into the run, after the bootstrap step had already created a fresh
S3 state bucket. With a one-second preflight, the agent would have
known to escalate to the user before doing any work. The rule's
cost is one shell invocation per session; the benefit is bounded
by the cost of one CI dispatch round.
