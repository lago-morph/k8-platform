# Next-session prompt — auto-015 (NEW AWS account)

> Copy-paste the block below to start the next session. Context: auto-014 merged
> the test-overhaul Track A (13 behavioral checks) + the scoped-role wiring + four
> owner-decision briefs + P3 (account-mutex + reaper-select) to `main` (PRs
> #191–#199). The previous AWS account is gone; this session runs on a **fresh
> account**, so nothing live is provisioned yet and no evidence exists for any SHA.

---

You are continuing the k8-platform test-overhaul on a **brand-new AWS account**
(the prior account `878302603783` is gone — assume zero live resources). All
auto-014 code is on `main`. Work on a feature branch; stacked PRs; ready-for-review.

ACCESS REALITY (do not repeat last session's mistake): you have **full admin AWS
API** creds AND **kubectl via the SSM relay**. The relay kubectl identity is
mapped to a view policy — but TEST your write access (try, don't assume), and use
`workflow_dispatch` of the CI workflows for any clean-build validation (§6.35).
Do NOT call the sandbox "read-only" — it isn't.

READ FIRST: `run-summary-auto-014.md`, `ai/handoff.md`, ADR-0006,
`planning/test-overhaul/FINAL-PLAN.md` §16 (P3–P6), the four briefs in
`planning/test-overhaul/decisions/auto-014-00*.md`, and `docs/open-issues.md`
OI-2026-06-08-1 / -2.

RUN ORDER:

1. **Bring up the substrate** on the new account: terraform phases 0→1, then the
   platform cluster via ArgoCD GitOps (the committed `platform-cluster-claim`),
   exactly as the sandbox-kubectl bring-up did (ai/handoff.md has the recipe).
   Verify hub + spoke reach `Ready` via the relay.

2. **Apply the scoped role + confirm the live gate end-to-end (STEP 0 on the new
   account).** Dispatch `terraform-test.yml` `apply-and-verify` (management) — this
   applies the verifier/reaper role WITH the three read verbs auto-014 added
   (`acm:ListTagsForCertificate`, `iam:ListRoles`, `iam:ListRoleTags`). Then
   dispatch `live-verify.yml` and confirm the producer goes **GREEN** on the
   10-kind `LIVE_EXPECT_FULL` (`live-verify-run.sh`): rds, acm Certificate/
   CertificateValidation, eks Cluster/NodeGroup/AccessEntry/AccessPolicyAssociation,
   iam Role/RolePolicyAttachment, route53 Record. Finally, open a trivial
   `crossplane/**` PR and confirm its `live-evidence-verify` flips GREEN on the
   fresh evidence. If a declared kind isn't provisioned on the new account, it
   correctly goes RED — provision it or adjust `LIVE_EXPECT_FULL` to reality (do
   NOT green-wash).

3. **Flip the 4 currently-SKIP kinds to PASS — and treat their auto-014 SKIPs as
   suspect, not settled.** Root cause for 3 of them: **`XSpokeAccess` is
   `MANUAL-SYNC ONLY`** (`argocd/apps/spoke-access.yaml` has no `syncPolicy.automated`)
   and was never synced, so the spoke **OIDC provider** (`xspokeaccess.yaml:101–137`,
   IRSA — trusts the spoke EKS issuer, NOT Cognito) and the **external-dns inline
   RolePolicy** (`xspokeaccess.yaml:207–278`) never existed. → **Manually sync
   `spoke-access` after the spoke is Ready + the oidcIssuer overlay is applied**,
   then both PASS. (There is NO Cognito / Cognito-OIDC in committed source — if the
   owner expects one, that is a design gap to raise, not a check miss.)
   - **secretsmanager Secret** skipped because only a value-less chainsaw leftover
     existed; a real `XPlatformSecret`/`PlatformSecret` claim makes it real.
   - **ExternalSecret — the auto-014 SKIP was NOT trustworthy (real check gap).**
     Keycloak's committed `XPlatformSecret` (`platform-services/keycloak/secrets/
     keycloak-secrets.yaml`, wave 35) emits an ExternalSecret **on the SPOKE**, but
     the auto-014 check ran against `k8-platform-mgmt` and the spoke relay flaked, so
     it may have missed a live spoke ExternalSecret. **Fix the check** to cover the
     spoke reliably (self-grant cluster access per §6.37; do NOT treat a flaked relay
     as "0 found" — that is a false SKIP). The broad ESO PushSecret→ASM→ExternalSecret
     baseline (ADR-0005) is still decided-but-unimplemented (OI-2026-06-07-1/-2/-5) —
     implementing it is what makes mgmt-side ExternalSecrets exist.
   Then add each kind to `LIVE_EXPECT_FULL` as it becomes real. (SecurityGroupRule +
   ExternalSecret need the relay/kubectl, which a CI runner lacks — keep them out of
   the CI producer's expect-full unless the runner gains that tooling, or run them
   from a self-granted sandbox/relay lane.)

4. **Resume Track B (the deferred work), driving the REAL controller, not admin
   AWS writes** (ADR-0006; validate on a clean build via CI, §6.35):
   - **Wire P3 into the live runner:** `tests/live/run.sh` should acquire the
     account-mutex lease (`tests/live/lib/account-mutex.sh`) before the
     instantiate/negative tiers, renew during, release after; and run the reaper
     FIRST using `reaper_decide` (`tests/live/lib/reaper-select.sh`) + the live
     `tags:GetResources` enumerate → dry-run → tag-conditioned deletes. Both libs
     are unit-tested; the mutex is live-validated.
   - **P4** — the parametrized hermetic instantiate-and-verify harness, proven on
     two maximally-different kinds (ASM Secret with its force-delete window + a
     global IAM Role), per brief auto-014-001's final hermetic set
     (`iam Role`, `secretsmanager Secret`); RolePolicy/RolePolicyAttachment/
     ExternalSecret are `singleton-coupled` (instantiate the enclosing XR as the
     atomic unit, never bare MRs — they carry a foreign-key on the Role).
   - **P5** — XRD/AppProject/RBAC/confused-deputy negatives that PROVE THE GUARD
     FIRED (red-first), the app-level Keycloak-DB gate, the hub-side spoke GitOps
     watch.

5. **Owner-decision follow-ups (both have open issues):**
   - **OI-2026-06-08-1** (Resource:* tightening): with a clean bring-up available
     to validate, narrow the provider IAM policy's `Resource:"*"` to
     `arn:aws:iam::<acct>:role/k8-platform-*` + `oidc-provider/*` FIRST (the safe
     subset the security-hawk reviewer identified), ship the paired deny test
     (`iam:CreateRole` denied for a non-`k8-platform-*` ARN), and add the
     scope-regression guard. Implement `scripts/derived-arn-inventory.sh` (stub).
   - **OI-2026-06-08-2** (hub→spoke e2e): once `hello.platform.<domain>` resolves,
     build the bounded-poll public-NLB curl e2e as a HARD check (wait_for ≥300s,
     HTTP 200 + expected body), paired with a hub-side ArgoCD `spoke-hello`
     Synced/Healthy assertion. NO self-gating SKIP stub.

CONSTRAINTS (unchanged): ADR-0006 NON-GOALs (no probe pod, no new AssumeRole
principal, no IAM trust widening, no provider-SA token mount); the verifier/reaper
stays zero-wildcard; `LIVE_MODE=mutating` fail-closed off by default; instantiate/
negative only under `LIVE_PROFILE=full`.
