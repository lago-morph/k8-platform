# Spec: `preflight-aws-account`

## Intent

Before dispatching `terraform-test.yml apply-and-verify`, confirm the
target AWS account has the prerequisites the workflow assumes — most
importantly a pre-existing public Route53 hosted zone. The 2026-05-23
session lost ~10 minutes (workflow run + log fetch + diagnosis) to a
fresh AWS account that lacked the zone; the workflow correctly aborted
mid-job with a clear message, but the agent could have known before
dispatching with a single command.

This skill is a fast, read-only check that mirrors exactly what
`terraform-test.yml`'s Bootstrap + Discover Route53 zone steps will
do, runnable locally or via a CI-only dispatch path. It is the
companion to `tests/e2e/test_route53_zone.sh` but designed to be the
*first* thing an agent runs when picking up a session — before any
expensive dispatch.

## Trigger

**Direct user phrases:**

- "Is the account ready?"
- "Check the AWS env"
- "Preflight"

**Proactive triggers:**

- Before the first `apply-and-verify` dispatch in any session.
- After AWS credentials in GitHub Secrets are known to have changed
  (user mention, or `aws sts get-caller-identity` returns a different
  account ID than the value cached from a prior run).
- When `terraform-test.yml` fails at the Discover Route53 zone step
  (post-hoc confirmation, helps with retry decisions).

**Negative triggers:**

- Routine same-session reruns where the account hasn't changed.

## Inputs

- `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION` available
  to the shell (locally or via `gh secret list` if running in CI).
- Optional `--region <region>` override.
- No cluster state needed — this runs before any apply.

## Outputs

- Exit 0 if every prerequisite is met; non-zero otherwise.
- Stdout: a fixed-order summary block, one line per check, terminated
  by `OK: preflight passed` or `FAIL: <reason>` so agents can grep.
- Stderr: human-readable detail on failure (account ID, missing
  resource, AWS error if any).

## Workflow

1. Verify `aws sts get-caller-identity` succeeds. Capture the account
   ID and ARN.
2. Verify `AWS_REGION` is set; warn if it isn't, but continue.
3. Verify exactly one public hosted zone exists in Route53. Print its
   name and ID. If zero zones: emit
   `FAIL: no public Route53 hosted zone in account <id>` and exit 1.
   If more than one: emit a warning (CI auto-picks the first) and
   continue.
4. Verify the EC2 quota allows at least 2 t3.medium instances. Call
   `aws service-quotas get-service-quota` for the relevant code; if
   unable to query quotas (some accounts), skip with a notice.
5. Verify no leftover resources from a prior session would block this
   one — e.g. orphan NAT gateways consuming EIPs. List EIPs in use.
6. Print summary block; exit accordingly.

## Concrete examples

### Example 1 — fresh account, no zone

```
$ scripts/preflight-aws-account.sh
sts: arn:aws:iam::767397674325:user/cloud_user (account 767397674325)
region: us-east-1
hosted zones: 0
FAIL: no public Route53 hosted zone in account 767397674325
$ echo $?
1
```

The agent reading this should immediately escalate to the user — no
amount of code change fixes a missing prerequisite — and not dispatch
apply-and-verify.

### Example 2 — account ready

```
$ scripts/preflight-aws-account.sh
sts: arn:aws:iam::975050256915:user/cloud_user (account 975050256915)
region: us-east-1
hosted zones: 1 (975050256915.realhandsonlabs.net / Z10163962DYPN2XZL1IM0)
EC2 instances in use: 0 / 9 quota
EIPs in use: 0 / 5
OK: preflight passed
```

The agent proceeds with `phase=base, action=apply-and-verify`.

## Anti-patterns

- **Do not** infer the account is ready from a previous session's
  state file. The state bucket name is derived from account ID and
  will appear "fresh" on a new account; that does not imply zone
  presence.
- **Do not** make this skill the first step of every CI job. The CI
  job already does equivalent work; the skill exists for the
  pre-dispatch local check. Adding it to CI is redundant work and a
  potential source of drift.
- **Do not** silently pick a zone when more than one exists — that
  reproduces the `route53 list-hosted-zones [?Config.PrivateZone==false]
  | [0]` selection in the workflow, which is intentional but fragile.
  Emit a warning so the user can confirm which zone CI will use.

## Acceptance criteria

1. Returns non-zero in <5s on an account missing the hosted zone.
2. Returns zero in <5s on a known-good account.
3. Output format is machine-parseable: `OK:` / `FAIL:` prefix on the
   last line.
4. Does not require kubectl, helm, or terraform — only `aws` and `jq`.
5. Documented in `scripts/README.md` and called out in
   `ai/handoff.md`'s "Picking up a session" subsection.

## Files this skill creates / modifies

- `scripts/preflight-aws-account.sh` — the script itself.
- `scripts/README.md` — add a row.
- `ai/handoff.md` — call out the script in the new-session quickstart.
- (Optionally) a new entry in `tests/e2e/` that wraps this script for
  inclusion in `phase=test, action=test-e2e`.
