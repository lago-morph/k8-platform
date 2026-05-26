# 30 — SEG-2 Review R1B (Correctness)

**Reviewer:** opus adversarial reviewer — CORRECTNESS angle
**Target:** `20-plan-SEG-2-terraform-infra.md`
**Verdict:** **REVISE-MINOR**

---

## Top correctness findings

### 1. (MAJOR-ish) "v2.3 promoted Function to v1" is misattributed — but conclusion still holds

Plan §2 step 2: *"Crossplane v2.3 promoted `Function` to `pkg.crossplane.io/v1`"*.

Independently verified: `Function.pkg.crossplane.io/v1` is present on
**Crossplane v1.17.1** (CRDs.dev shows `Function.v1.pkg.crossplane.io@v1.17.1`).
The promotion happened on the v1.x line — well before v2.3. The v2.3.0
release notes (verified directly) make **no mention** of a Function v1
promotion. The plan's release-note citation is wrong.

Consequence: the **edit is still correct** (use `pkg.crossplane.io/v1`),
but the rationale "v1beta1 may still resolve via conversion" is shakier
than the plan implies — on v2.3 the v1beta1 CRD almost certainly **no
longer exists** as a served version, which means the current heredoc
applying `v1beta1` would silently fail (`no matches for kind
"Function" in version "pkg.crossplane.io/v1beta1"`) on a fresh cluster.
Open question 2 ("does the conversion webhook handle it") is therefore
the wrong framing — there is no webhook, only one served version.

**Fix:** drop the "v2.3 promoted" claim; cite the correct earlier
release (or simply "v1 is the only served version on v2.3"); reframe
open question 2 as "verify v1beta1 is not served on v2.3 and that the
current Terraform actually fails before the bump rather than after."

### 2. (MINOR) SA-name claim verified, but caveat understated

Plan §2 cites docs.crossplane.io/latest/packages/providers/ saying
`serviceAccountTemplate.metadata.name` overrides. **Independently
confirmed verbatim:** *"Setting the `serviceAccountTemplate.metadata.name`
field will override the name of service account created by the package
manager and used in the provider deployment."*

However the same page recommends an **alternative pattern**
(`deploymentTemplate.spec.template.spec.serviceAccountName` on a
pre-existing SA) and warns the override path causes the package manager
to "own" the SA, with conflicts if reused. The plan's fallback (§4 path
b) cites this exact alternative but buries it. Given the warning is
upstream-official, the plan should flag it as known-fragile, not
"strongly discouraged" hand-wave.

### 3. (MINOR) Helm chart `--set` args unverified against v2.3

`helm.tf:152–161` passes `--enable-realtime-compositions=false`,
`--enable-ssa-claims=false`, `--enable-custom-to-managed-resource-conversion=false`.
Plan §1 lists `helm.tf:helm_release.crossplane` as `APPLY-OK-NOOP` and
doesn't audit these flags. The v2.3.0 release notes I fetched do not
mention these flag names; if any were renamed or removed, Helm will
either silently ignore or hard-fail at chart-install time. Plan must
add a verification step (e.g., `helm show values crossplane --version
2.3.0 | grep -E 'realtime|ssa|managed-resource'`) before declaring this
block NOOP.

## Independently verified upstream fact

`DeploymentRuntimeConfig.serviceAccountTemplate.metadata.name`
**does** override the package-manager default SA in Crossplane v2.3 —
verbatim from docs.crossplane.io/latest/packages/providers/. IRSA
trust-policy round-trip (`crossplane-system:upbound-provider-family-aws`)
is intact provided the DRC applies before the pod is rendered, which
the existing `kubectl delete deploy` hack guarantees.

## Provider package heredoc / IRSA — no other issues

- `pkg.crossplane.io/v1 kind: Provider` and `runtimeConfigRef` pointing
  at a v1beta1 DRC: both v2-valid.
- IRSA trust-policy pin in `irsa.tf:98` unchanged — correct given (2).
- No v1-only flags in the Provider spec.

---

**Verdict: REVISE-MINOR.** Fix the Function-promotion attribution and
reframe open question 2; add the helm-flag audit. Core plan is sound.
