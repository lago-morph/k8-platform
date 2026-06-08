# Scoped verifier/reaper IAM role for the LIVE test harness (FINAL-PLAN §3.4).
#
# Correction #2 opened a genuine hole: appending tests/live/run.sh as a step in
# terraform-test.yml's apply-and-verify job would run the verifier, reaper, and
# the reaper's cross-service DELETES as the ADMIN CI principal — a worse blast
# radius than the one the overhaul retires from Crossplane. So the build flow's
# identity is SPLIT: `terraform apply` keeps admin (unavoidable for bootstrap);
# tests/live/run.sh re-scopes via `sts assume-role` into THIS role, which never
# holds terraform-apply-grade power.
#
# NON-GOAL boundary (spine): this is the verifier/reaper HARNESS identity. It is
# NOT a new AssumeRole principal that impersonates the Crossplane controller, NOT
# a trust-policy widening on the provider role, and NOT a probe-SA path. The
# controller's create-path permission is still proven only by driving the real
# controller under `source: IRSA`. This role observes/reaps AROUND that test.
#
# The policy is a COMMITTED, ZERO-WILDCARD-ACTION artifact (no `service:*`/`verb*`
# in any Action; the §3.3 ceiling lint covers it at K=0). Reaper deletes are
# per-service AND tag-conditioned on the `live-verify` run-id tag in the policy
# itself (defense-in-depth, since the runtime three-predicate AND is the very
# thing under test and a bug in it under admin deletes real infrastructure).

locals {
  # The CI principal allowed to assume this role. The terraform-test.yml runner
  # authenticates with the account's CI credentials; restrict the trust to that
  # principal's account root (the account is single-tenant ephemeral). A tighter
  # trust to a named CI role ARN is a follow-up once that role exists.
  verifier_lock_table = "k8-platform-live-verify-lock"
}

data "aws_iam_policy_document" "verifier_reaper_trust" {
  statement {
    effect = "Allow"
    # sts:TagSession is REQUIRED alongside AssumeRole: the condition below
    # demands a live-verify *request tag*, and a request tag can only be set by
    # passing --tags at assume time, which triggers an sts:TagSession permission
    # check. Granting only sts:AssumeRole makes the tagged assume fail closed
    # with "not authorized to perform: sts:TagSession" (verified by spike
    # 2026-06-08 before this CI wiring) — so the role could never be assumed the
    # one way the trust policy allows. Both actions share the same tag guard.
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${local.account_id}:root"]
    }
    # Defense-in-depth: only sessions tagged with a live-verify run id may assume.
    condition {
      test     = "StringLike"
      variable = "aws:RequestTag/live-verify"
      values   = ["*"]
    }
  }
}

resource "aws_iam_role" "verifier_reaper" {
  name                 = "${var.cluster_name}-live-verifier-reaper"
  description          = "Scoped, zero-wildcard-action verifier/reaper harness identity for tests/live (FINAL-PLAN §3.4)"
  assume_role_policy   = data.aws_iam_policy_document.verifier_reaper_trust.json
  max_session_duration = 3600

  tags = {
    "k8-platform/purpose" = "live-verify-harness"
  }
}

resource "aws_iam_policy" "verifier_reaper" {
  name        = "${var.cluster_name}-live-verifier-reaper"
  description = "Zero-wildcard-action verify reads + tag-conditioned reaper deletes + account-mutex store"
  policy = templatefile("${path.module}/policies/verifier-reaper-policy.json.tftpl", {
    account_id = local.account_id
    region     = local.region
    zone_id    = local.zone_id
    lock_table = local.verifier_lock_table
    # The reaper assumes the role with a per-run live-verify session/resource tag;
    # the policy's delete Condition pins deletes to resources carrying it. The
    # concrete run id is supplied at assume time; the policy template uses a
    # wildcard-free placeholder rendered to the literal tag KEY match.
    run_id_tag = "$${aws:PrincipalTag/live-verify}"
  })
}

resource "aws_iam_role_policy_attachment" "verifier_reaper" {
  role       = aws_iam_role.verifier_reaper.name
  policy_arn = aws_iam_policy.verifier_reaper.arn
}

# Account-mutex backing store (FINAL-PLAN §8): a single-row DynamoDB lock the
# reaper and concurrent runs use to serialize destructive sweeps. Pinned here so
# the policy ARN above resolves; age-floor/lease-TTL logic lives in the reaper.
resource "aws_dynamodb_table" "live_verify_lock" {
  name         = local.verifier_lock_table
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "lock_id"

  attribute {
    name = "lock_id"
    type = "S"
  }

  tags = {
    "k8-platform/purpose" = "live-verify-account-mutex"
  }
}

output "live_verifier_reaper_role_arn" {
  description = "ARN of the scoped verifier/reaper harness role (tests/live assumes this, not admin)."
  value       = aws_iam_role.verifier_reaper.arn
}
