# Spec: `crossplane-iam-policy-completeness-audit`

- **ID**: SKILL-SPEC-e0eea06695
- **Source retrospective**: ../2026-06-07-165.md

## Intent

When a Crossplane Composition (using the upbound AWS provider via a shared IRSA
ClusterProviderConfig) is about to be relied on live, the crossplane IRSA policy must
grant every AWS API action that each managed-resource (MR) kind the Composition
renders needs across its FULL upjet lifecycle — create, observe (Get/Describe),
update, delete, and tag/untag. Missing actions fail **closed** at apply time with
`AccessDenied`, and because upjet surfaces them one phase at a time (create succeeds,
then the next reconcile's Get/Update/Tag fails), they appear one-at-a-time across
many expensive live reconcile loops. In auto-012 this cost four separate
discover→edit-policy→wait rounds (`iam:TagOpenIDConnectProvider`,
`iam:UpdateAssumeRolePolicy`, `iam:GetRolePolicy`, the entire `rds:*` set). A
one-pass audit that maps MR kinds → required actions and diffs against the live/
committed policy catches them all before the first live dispatch.

## Trigger

- Direct: "audit the crossplane policy", "will this composition's MRs have perms",
  "check IRSA permissions for <composition>".
- Proactive: before the first live sync/apply of any new or substantially-changed
  Composition that adds MR kinds; before phase sign-off for a phase that adds a
  Composition; when an MR is observed `Synced=False` with an `AccessDenied` message.
- Negative: pure value/patch changes to an existing Composition that add no new MR
  kind and no new tagged/named field.

## Inputs

- The Composition file(s) under `crossplane/compositions/`.
- The crossplane IRSA policy source (`terraform/management/irsa.tf`) and/or the live
  policy (`aws iam get-policy-version`).
- Knowledge of the upjet resource kinds' lifecycle API calls (encoded as a per-kind
  action table in the skill).

## Outputs

- A report listing, per MR kind in the Composition, the required actions and whether
  each is granted (exact, service-wildcard, or prefix-wildcard).
- A concrete diff: the actions to ADD to the policy (with a ready-to-paste statement).
- Optionally, an extension to `tests/unit/fixtures/iam/crossplane-aws.txt` so the gap
  becomes a regression.

## Workflow

1. Parse the Composition: collect every `base.apiVersion`/`kind` (the MR kinds) and
   note which set `tags`, an inline policy, an assume-role policy, or a name.
2. For each kind, look up its upjet lifecycle action set (Create/Get-or-Describe/
   Update/Delete + Tag/Untag if it carries tags; for inline sub-resources like
   RolePolicy, the Put/Get/Delete/List quartet).
3. Extract the granted actions from the policy (handle `service:*` and `verb*`
   wildcards).
4. For each required action not granted, emit a FAIL with the kind, the action, and
   the lifecycle phase it blocks.
5. Emit a single consolidated "add these actions" statement.
6. If invoked with `--fix`, add the actions to `irsa.tf` + the fixture and re-run the
   IAM unit test.

## Concrete examples

**Example 1 — XSpokeAccess (auto-012).** Kinds: OpenIDConnectProvider (tags →
needs Create/Get/Tag/Untag/Delete), Role (assumeRolePolicy → needs
Create/Get/UpdateAssumeRolePolicy/Tag/Untag/Delete), RolePolicy (inline → needs
Put/Get/Delete/List), AccessEntry, AccessPolicyAssociation. The committed policy had
Create/Delete/Get OIDC but not Tag; Create/Get/Delete/Tag Role but not
UpdateAssumeRolePolicy; Put/Delete/List RolePolicy but not Get. The audit would have
emitted three FAILs in one pass instead of three live rounds.

**Example 2 — XDatabase RDS.** Kind: rds Instance. The policy had ZERO `rds:*`. The
audit emits: add `rds:CreateDBInstance/DescribeDBInstances/ModifyDBInstance/
DeleteDBInstance/AddTagsToResource/ListTagsForResource` (+ DBSubnetGroup if a
SubnetGroup MR is present). Caught before the first XR sync.

## Anti-patterns

- Granting `iam:*`/`rds:*` blindly to dodge the audit — over-broad; enumerate.
- Auditing only `Create` — upjet's Observe (Get/Describe) and Update calls are the
  ones that bite after a successful create.
- Running the audit only after the first AccessDenied — the point is to run it BEFORE
  the live dispatch.

## Acceptance criteria

1. For a Composition with a known gap, the skill reports the exact missing action(s).
2. It handles `service:*` and `verb*` wildcard grants without false positives.
3. It distinguishes tagged vs untagged MRs (Tag actions only required when tags set).
4. `--fix` produces an `irsa.tf` + fixture change that makes the IAM unit test pass.
5. Re-running after a fix reports zero gaps (idempotent).

## Files this skill creates / modifies

- (report only by default) — prints to stdout.
- With `--fix`: `terraform/management/irsa.tf`,
  `tests/unit/fixtures/iam/crossplane-aws.txt`.
