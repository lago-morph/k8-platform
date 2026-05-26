# 30 — Review SEG-2 R1A (sequencing)

**Reviewer angle:** execution + sequencing
**Target:** `20-plan-SEG-2-terraform-infra.md`

## Verdict

**REVISE-MINOR.** Core ordering is sound; PR #98 dependency is correctly
declared (§6 L281, §2.1 L94-97). Three concrete sequencing gaps are worth
fixing before the PR opens — none are deal-breakers.

## Does well

- **Accepts PR #98 as an upstream prereq instead of re-bumping** (§6 L281,
  §2.1 L94-97). The `triggers_replace` analysis at L215-224 of `helm.tf`
  correctly justifies why the version-string change alone re-fires the
  local-exec — no manual touch needed.
- **Sequence diagram** (§1 L40-63) gets the IRSA token-exchange ordering
  right: trust policy lands at apply, SA at package reconcile, STS call
  only after pod start. Failure mode at L65-68 is precise.
- **Failure recovery table** (§4) anticipates the v1beta1→v1 Function
  conflict and supplies the `kubectl delete function` mitigation.

## Sequencing flaws

1. **DRC SA-name cutover races provider re-render.** When `triggers_replace`
   fires (`helm.tf:215-224`), the DRC is re-applied and then `kubectl delete
   deploy -l ...provider=provider-family-aws` (L242-244) is fire-and-forget
   (`--wait=false || true`). The new pod can come up before the OLD SA
   `upbound-provider-aws-<hash>` is garbage-collected; both SAs may briefly
   coexist. If Crossplane's package manager re-creates the hash-suffixed SA
   _after_ the DRC apply (race on watch lag), the pod mounts the wrong
   token. Plan §2.3 asserts the override is correct but never adds a
   `kubectl rollout status` or SA-name post-check. Add one.

2. **Function apiVersion: delete-first vs trust-webhook decision is left
   open.** §2.2 (L106-128) prescribes the v1beta1→v1 change but defers
   the "does the conversion webhook handle existing v1beta1 objects?"
   question to step 6's kind probe (§3 Q2 L235-239). The wrong answer's
   blast radius is concrete: `terraform_data.crossplane_function_patch_and_transform`
   (`helm.tf:255-278`) re-apply fails → terraform apply hard-fails →
   cluster left mid-migration with provider-family-aws v2.5.4 installed but
   no Function → every Composition pipeline fails to render. Pre-stage the
   `kubectl delete function function-patch-and-transform --ignore-not-found`
   from §4 row 2 _unconditionally_ in the local-exec body rather than as a
   contingency. Cost is one line; eliminates the rollback window.

3. **Kind probe is non-representative for IRSA.** §2.6 L188-217 only
   verifies SA naming. It does NOT verify that (a) the DRC override
   survives the `kubectl delete deploy` re-render cycle that ONLY fires
   in the terraform path, nor (b) that the SA carries the IRSA
   annotation in a form EKS STS will accept (kind has no OIDC issuer).
   The plan claims the probe validates the load-bearing unknown; it
   validates half of it. State the limitation explicitly and add a
   post-apply CI assertion (`kubectl get sa -n crossplane-system
   upbound-provider-family-aws -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}'`).

## Cross-segment hazards

- **No-rollback window after apply.** Once `triggers_replace` fires
  (`helm.tf:215`), the v2.5.4 Provider object replaces the v1.12.0 one
  in-cluster. Reverting `variables.tf` re-runs the local-exec with the
  v1 URL but does NOT clean up v2 CRDs the provider installed
  (`*.aws.m.upbound.io`). A revert leaves a mixed-group cluster. Plan
  §4 doesn't acknowledge this — add a "post-apply revert requires
  manual `kubectl delete crd -l...`" note.
- **DRC update timing vs SA cleanup.** §2.3 L143-144 says the delete-deploy
  hack stays, but doesn't say _when_ the old hash-suffixed SA gets GC'd.
  If Crossplane owns the SA (per the v2 docs quoted in §2 L82-84), package
  uninstall reaps it; an in-place version bump may not. Confirm in the
  kind probe whether the old SA persists after re-render.
- **SEG-1 dependency declared but not gated.** §6 L283-285 says SEG-1
  depends on this PR, but SEG-1's ArgoCD sync fires automatically from
  `terraform_data.argocd_bootstrap` (`helm.tf:418-435`) on every apply.
  If SEG-1's manifests aren't yet merged to `main`, this PR's apply
  re-syncs the v1 manifests against the v2 provider → ADMISSION-REJECT
  storm. Either pin the bootstrap to a SHA or pause the bootstrap
  Application during the SEG-2 → SEG-1 window.

## Suggested fixes (minimal diff)

1. Add `kubectl rollout status -n crossplane-system deploy -l
   pkg.crossplane.io/provider=provider-family-aws --timeout=180s`
   after the delete-deploy in `helm.tf:244`, then assert SA name and
   annotation.
2. Unconditionally pre-delete the v1beta1 Function before re-applying
   as v1 in `helm.tf:260-274`; bump `triggers_replace` sentinel.
3. Expand §2.6 probe to include (a) re-apply DRC + delete-deploy cycle,
   (b) explicit SA-annotation read-back; document IRSA-on-kind caveat.
4. Add a §4 row for "revert after v2 apply" → manual CRD cleanup.
5. Gate `argocd_bootstrap` (or pause the Application) until SEG-1 lands.
