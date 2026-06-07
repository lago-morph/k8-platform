# Round-2 adversarial review — K8s/Crossplane mechanism correctness

**Reviewer persona:** unit+integration testing expert, deep in the
administrative side of Kubernetes (CRDs/operators/controllers, admission, RBAC,
GitOps reconciliation, Crossplane compositions, policy engines). I authored one
of the source plans; here I attack the merged `SYNTHESIZED-PLAN.md` cold, as an
adversary of the result.

**Scope of attack (per brief):** does "drive the real controller under its own
IRSA + verify via crossplane-claim-verify" actually work and exercise the
restricted identity? Are the identity assertions checkable as described? Will the
DERIVED coverage manifest parse the real composition structure? Is the spoke
XR-Ready trigger real? Are negatives using the right k8s mechanisms?

I read the plan fully and verified every load-bearing claim against the repo
(`crossplane/**`, `terraform/management/irsa.tf`, `terraform/management/crossplane-phase3.tf`,
`tests/integration/run.sh`, `tests/unit/test_iam_required_actions.sh`, the
`crossplane-claim-verify` skill, `policies/audit/**`). Findings cite line/file.

**Verdict up front:** the plan's *center of gravity* (drive the real controller,
no probe SA, simulate-principal-policy for completeness, derived coverage, skip
floor) is the right architecture and must survive finalization. But several of
its concrete k8s/Crossplane *mechanism* claims are factually wrong against this
repo, and at least two of those are load-bearing for the plan's central promise
("identity is falsifiable"). They are fixable, but they MUST be fixed before P4,
because P4 builds on them.

---

## CRITICAL

### C1 — The identity assertion keys on the WRONG credentials source. The AWS provider is `source: IRSA`, NOT `InjectedIdentity`. The plan conflates two different ProviderConfigs.

This is the single most damaging factual error, because §2.2 is the plan's
answer to "make 'under IRSA' falsifiable" — the falsifiability of the whole
mechanism rests on it.

The plan says, repeatedly and as a checkable assertion:

> §2.1: "apply a real ... XR (Crossplane v2 ...) and let the provider controller
> reconcile it under its own injected identity"
> §2.2.1: "The active ProviderConfig is `InjectedIdentity`/IRSA"
> §2 header: "proved against `terraform/management/irsa.tf:174` that the provider
> role's trust policy permits exactly one subject:
> `crossplane-system:upbound-provider-family-aws` (`InjectedIdentity`)."

Against the repo this is wrong on two counts:

1. **The AWS family provider uses `source: IRSA`, not `InjectedIdentity`.**
   `crossplane/providerconfig/00-clusterproviderconfig.yaml:39-41` is literally:
   ```yaml
   spec:
     credentials:
       source: IRSA
   ```
   and the header comment (lines 24-30) is explicit: *"'IRSA' is a valid value of
   the provider's credentials.source enum [None, Secret, IRSA, WebIdentity,
   PodIdentity, Upbound]."* This is a **`ClusterProviderConfig`** of group
   `aws.m.upbound.io/v1beta1` — the AWS upbound v2 ("modern") provider. Every AWS
   MR base in every composition sets `providerConfigRef: {kind:
   ClusterProviderConfig, name: default}` (verified across platform-cluster.yaml,
   xspokeaccess.yaml, xdatabase.yaml, platform-secret.yaml).

2. **`InjectedIdentity` in this repo belongs to a DIFFERENT provider entirely —
   provider-kubernetes**, not the AWS provider. `crossplane-phase3.tf:232-241`
   creates a `kubernetes.crossplane.io/v1alpha1` ProviderConfig named `hub` with
   `source: InjectedIdentity`, used by provider-kubernetes to write the ArgoCD
   spoke cluster Secret into the hub. That config uses the *crossplane in-cluster
   SA* directly (no AssumeRole), which is exactly why it is `InjectedIdentity`. It
   has nothing to do with the AWS IRSA role.

**Why this is Critical, not pedantic:** §2.2.1 instructs every `real-irsa` test
to *assert* "the active ProviderConfig is InjectedIdentity/IRSA." A test that
literally checks `source: InjectedIdentity` on the AWS path will **always FAIL**
(the value is `IRSA`), and a test that accepts *either* string as "good" is
asserting nothing — it would pass against a misconfigured `source: WebIdentity`
or even a static-cred `Secret` config if the author got the enum wrong. The plan
also misattributes the falsifiability proof to "irsa.tf:174 (InjectedIdentity)"
— but irsa.tf:174 is the *trust-policy subject* of the IRSA **role**, a
different artifact from the *ProviderConfig credentials.source*. The two are
being treated as the same fact.

**Fix:**
- Rewrite §2 throughout: the AWS identity mechanism is **`source: IRSA`** on
  `ClusterProviderConfig/default` (group `aws.m.upbound.io`). The assertion is:
  `kubectl get clusterproviderconfig.aws.m.upbound.io/default
  -o jsonpath='{.spec.credentials.source}'` == `IRSA` AND no second
  `ClusterProviderConfig`/`ProviderConfig` of the AWS group with `source: Secret`
  exists AND no `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` in the
  `upbound-provider-family-aws` pod env.
- Remove every "InjectedIdentity" reference from the AWS-identity discussion;
  reserve InjectedIdentity for the provider-kubernetes `hub` config discussion
  (it is relevant to the spoke-Secret write path in §8, not to AWS IRSA).
- The IRSA mechanism for the AWS provider is: the
  `crossplane-system:upbound-provider-family-aws` SA is annotated
  `eks.amazonaws.com/role-arn=<cluster>-crossplane` (DeploymentRuntimeConfig in
  `helm.tf`), provider does `AssumeRoleWithWebIdentity` via the projected token.
  State that explicitly — it is checkable and the plan currently mis-states it.

Finalization MUST NOT preserve the word "InjectedIdentity" anywhere it describes
the AWS provider's identity.

---

### C2 — The "derived coverage manifest" cannot parse `resources[].base.kind` from these compositions: they are Pipeline-mode, MR kinds live under `spec.pipeline[].input.resources[].base.kind`, and the list is polluted by function `Input`/`Resources` kinds and non-AWS provider-kubernetes kinds.

§3.5 is the resolution to CRITICAL #6 ("hand-edited manifests get edited to go
green") and is named a P1 deliverable. Its derivation rule is:

> "Derive the provisioned-thing set from `crossplane/**` (XRD/Composition
> `resources[].base.kind` = the MR kinds)"

This path does not exist in these compositions. All four compositions are
**`mode: Pipeline`** (verified: platform-cluster.yaml:68, and the
`function-patch-and-transform` step shape in all four). The MR bases are nested:

```
spec.pipeline[<patch-and-transform step>].input.resources[].base.kind
```

A naive `yq '.spec.resources[].base.kind'` returns nothing. Worse, a blunt
recursive `..|.kind?` grab over the file (the obvious fallback) returns a list
**polluted** by:
- `kind: Composition` (the doc itself),
- `kind: Input` (the function-environment-configs step input,
  platform-cluster.yaml:84),
- `kind: Resources` (the function-patch-and-transform input wrapper, line ~92),
- `kind: ClusterProviderConfig` (appears once per resource in
  `providerConfigRef`, ~11x per composition — these are NOT MRs),
- and in xspokeaccess.yaml, **provider-kubernetes `Object` kinds are not present
  here but the pattern invites them** — note xspokeaccess provisions
  `OpenIDConnectProvider`, `Role`, `RolePolicy`, `AccessEntry`,
  `AccessPolicyAssociation`, all `*.aws.m.upbound.io`, but the spoke-Secret write
  goes through a *separate* provider-kubernetes path (auto-008 C5,
  crossplane-phase3.tf) whose `Object` MR is the kind that would break an
  AWS-only simulate-principal-policy mapping if it ever lands in a composition.

**Then the second half breaks too.** §3.5 says derive "actions from
`irsa.tf`" *per component*. But `irsa.tf` is **one flat `aws_iam_policy`
"crossplane_aws"** with Sid-grouped statements (IAM/RDS/SecretsManager/ACM/
Route53Read/Route53Validation — verified lines 60-161). There is **no per-XRD
attribution** in it. You cannot derive "XDatabase needs `rds:*`, XPlatformCluster
needs `acm:*`" from irsa.tf — the policy doesn't carry that mapping. The
existing `test_iam_required_actions.sh` *fakes* this mapping with a
**hand-maintained `MAP=()`** (lines 31-35) and **hand-maintained fixture files**
(`tests/unit/fixtures/iam/{crossplane-aws,eso,external-dns}.txt`). So the plan's
claim that it "extends the existing pattern rather than inventing a parallel
file" actually means **extending a hand-maintained fixture** — i.e. exactly the
"second copy of truth that drifts/gets edited green" the plan says it is
replacing (§13 rejected: "hand-maintained coverage manifest"). The plan
contradicts itself here.

**Why Critical:** the anti-silent-regression promise (a missing test goes CI-red
at authoring time) is only as good as the derivation. If the derivation silently
produces an empty or polluted kind-set, `test_live_coverage.sh` passes with zero
required rows — a green that proves nothing, which is the precise failure mode
auto-012 paid 8 blockers for.

**Fix:**
- Specify the **exact** extraction path:
  `yq '.spec.pipeline[].input.resources[]? | select(.base) | .base.apiVersion +
  "/" + .base.kind'` over each `crossplane/compositions/*.yaml`, then
  **filter to `*.aws.*upbound.io` apiVersions only** for the
  simulate-principal-policy mapping, and route any `kubernetes.crossplane.io`
  (provider-kubernetes `Object`) kinds to a separate, non-AWS lane (they have no
  IAM action to simulate; they are hub-RBAC, not AWS).
- Drop the irsa.tf-as-per-component-source claim. The action→component mapping is
  **inherently hand-curated** in this repo; own that. Make the curated mapping a
  *reviewed registry* (the plan already concedes "the human maintains only the
  registry of which test defends which kind" — make that the ONLY hand-maintained
  thing, and derive the *kind list* it must cover from the compositions so an
  un-registered kind is CI-red). The two-sided floor/ceiling on irsa.tf stays
  useful for "no wildcard" and "required action present," but it is NOT the
  source of the per-kind coverage map.
- Add an `Input`/`Resources`/`ClusterProviderConfig`/`Composition` denylist to
  the extractor so function-wrapper kinds and providerConfigRef kinds never count
  as MRs. A unit test on the extractor itself (feed it the four real
  compositions, assert the kind-set equals the known MR set: Role,
  RolePolicyAttachment, Cluster, NodeGroup, Certificate, Record,
  CertificateValidation, OpenIDConnectProvider, RolePolicy, AccessEntry,
  AccessPolicyAssociation, Instance/SubnetGroup, Secret) is mandatory — otherwise
  the derivation is itself untested.

---

### C3 — `crossplane-claim-verify` is written for v1 *claims* (`<claim-kind>`, `spec.resourceRef`, `spec.resourceRefs`), but the repo is Crossplane v2 (no claim CRD; namespaced XR). Making it "mandatory and automatic" as written drives a broken loop.

§2.1 and §3.1 designate `crossplane-claim-verify` (+ `wait-for-claim.sh`) as the
sanctioned per-XR verification unit, "made mandatory and automatic." But the
skill's own text is v1-claim-shaped, and the repo migrated to v2:

- The example XR (`crossplane/claims/example-platform-cluster.yaml:1-26`) states
  outright: *"under Crossplane v2 there is no separate `PlatformCluster` claim
  type — XPlatformCluster is the user-facing namespaced XR
  (apiextensions.crossplane.io/v2 + scope: Namespaced)."*
- The skill `SKILL.md`:
  - Phase 1 (lines 47-58): "Locate the claim", uses `<claim-kind>` and
    `spec.resourceRef.name on the claim`. In v2 there is no claim; the user
    applies the XR directly.
  - Phase 3 (lines 79-86): walks `'{.spec.resourceRefs[*]}'`. On a v2 XR the
    composed-resource refs are **not** at `spec.resourceRefs` — v2 moved them
    (the XR carries them under `spec.crossplane.resourceRefs` / surfaced via
    `status`, depending on version). A jsonpath against `spec.resourceRefs` on a
    v2 XR returns empty → the descend step silently walks zero MRs → the skill
    reports "Synced/Ready" on the XR without ever checking the composed AWS MRs.
  - The Prerequisites (lines 39-40) say `kubectl get providers.pkg.crossplane.io`
    should return "`provider-aws` or similar" — the repo's provider is the
    **family** provider `upbound-provider-family-aws` plus child providers; a
    naive name match may miss it.
  - Phase 4 PlatformSecret example (line 100-101) base64-decodes secret `.data`
    into output — this is the exact CRITICAL #11 secret-spill the plan elsewhere
    forbids, *living in the skill the plan makes mandatory*. The plan notes this
    (§7.3) but does not flag that the skill file itself must be edited.

**Why Critical:** the plan leans on this skill as the load-bearing per-XR check
on every bring-up. If the skill silently walks zero MRs on a v2 XR, the
"behavioral verification" reduces to "the XR object reports Ready" — which is
*exactly* the manifest-says-X-not-X-works disease the overhaul exists to kill,
and would have *masked* several of the 8 blockers (a blocker on the EKS MR can
leave the XR Ready=False, but a blocker that leaves the XR Ready while a child MR
is stuck would slip through).

**Fix:**
- Add a P-level task: **port `crossplane-claim-verify` to v2** before it is made
  mandatory. Phase 1 = locate the **XR** (`kubectl get <xr-kind> -A`), not a
  claim. Phase 3 = walk the v2 composed-resource ref path (verify the actual
  field on the running cluster at spike time; do NOT assume `spec.resourceRefs`).
  Phase 4 PlatformSecret recipe = digest/length only, never decode (§7.3).
- The spike (§12) must include "the skill, in its v2 form, descends into and
  asserts every composed MR's Synced+Ready" as an explicit acceptance check —
  not just "the XR is Ready."
- `wait-for-claim.sh` (named alongside) must be audited for the same v1/v2 and
  auto-dump-secret issues; the plan references it without checking it.

---

### C4 — The "caller-ARN" identity assertion via CloudTrail is not reliably observable in-band, and the plan's own fallback (a pod using the provider SA running `sts get-caller-identity`) re-introduces the rejected probe-pod.

§2.2.2 offers two ways to prove "the caller identity Crossplane actually used ==
the expected IRSA role ARN":
(a) CloudTrail `userIdentity.arn` on the provisioned resource, or
(b) "`aws sts get-caller-identity` run by a pod using the provider SA."

Both have mechanism problems:

- **(a) CloudTrail** has management-event latency typically up to ~15 minutes
  (the plan half-acknowledges this in §14.1 and §4.2). For an "on every bring-up,
  cheap (sec–min)" BRING-UP bucket (§1 table), a 15-min CloudTrail wait blows the
  budget and the wall-clock ceiling (§11). And CloudTrail correlation
  ("*which* CreateRole event corresponds to *this* run's XR") requires matching
  on the run-id-prefixed resource name — workable, but only if every MR carries
  the run-id externally, which the IAM-role-name case does (good) but
  AccessPolicyAssociation / CertificateValidation may not.

- **(b) "a pod using the provider SA"** is **the probe pod the plan spent §2.1
  and §13 rejecting.** A pod that mounts/uses `crossplane-system:upbound-provider-
  family-aws`'s projected token to call STS *is* "mount/copy the provider SA's
  projected token into a probe pod" — explicitly listed as out-of-scope and
  "must be rejected in review" (§2.1 NON-GOAL). The plan contradicts its own
  non-goal in the very next subsection. (Note: a pod *scheduled as* that SA, vs a
  pod *copying its token*, are different — but a separate pod running as the
  provider SA is still a second workload assuming the role, which muddies the
  "only the provider controller assumes this role" cleanliness and could trip the
  un-exercised-grant accounting in §4.2.)

**Why Critical:** §2.2 is the *entire* falsifiability argument. If neither
method is actually usable in-band on every bring-up, the plan degrades to
"Synced + cloud-exists" (which §14.1 admits as the fallback) — and that fallback
does NOT distinguish "provisioned under the restricted IRSA role" from
"provisioned under the admin CI key via a sneaked-in static ProviderConfig,"
which is the precise wrong-path §2.2 exists to close.

**Fix:**
- Make the **primary, in-band** identity proof the *negative-space* check that is
  cheap and synchronous: assert there is **no** AWS-group `ProviderConfig`/
  `ClusterProviderConfig` with `source: Secret` and **no** static AWS creds in
  the provider pod env (this is the low-friction wrong-path §2.2 names, and it is
  checkable in <1s with `kubectl`). That closes the "admin-cred ProviderConfig
  layered over IRSA" hole directly, without CloudTrail.
- Keep the **caller-ARN==role-ARN** proof as an **AFTER-THE-FACT / async lane**
  (CloudTrail or access-analyzer), explicitly NOT in the per-bring-up budget —
  same treatment §4.2 already gives the un-exercised-grant tier. Run it once per
  spike and periodically, not every bring-up.
- Strike option (b) entirely, or rewrite it precisely: a one-shot Job whose
  `serviceAccountName` is a **dedicated, separately-trusted** read-only SA is
  fine; a pod borrowing the *provider's* SA/token is not. Pick one and align with
  the §2.1 NON-GOAL so reviewers aren't asked to enforce two contradictory rules.

---

## MAJOR

### M1 — Kyverno `Enforce` migration is treated as a flag flip; it is a cluster-wide admission-webhook change with a real outage surface, and the repo's policies are ALL `Audit` today.

§6 (multiple places) and the matrix rows #6 want certain Kyverno policies in
**Enforce** mode with `failurePolicy: Fail` ("an Audit policy 'guard' blocks
nothing" — correct). Verified: **every** policy under `policies/audit/` is
`validationFailureAction: Audit` (10/10 files), and the directory README says so.

Two mechanism cautions the plan under-weights:
1. Flipping `validationFailureAction: Enforce` **plus** `failurePolicy: Fail` on
   a `ClusterPolicy` means the Kyverno admission webhook becoming unavailable
   (pod evicted, upgrade, ENI exhaustion — a documented hub failure mode per
   AGENTS §6.24/§6.26) will **block all matching admissions cluster-wide**,
   including ArgoCD's own self-heal applies. That is a self-inflicted hub outage.
   The plan flags this risk for the *new* Kyverno DB admit-gate (§6,
   "mis-scoped cluster-wide gate is a self-inflicted outage") but not for the
   *existing* policies it wants promoted to Enforce (matrix #6, IRSA-SA-carries-
   role-arn).
2. `failurePolicy: Fail` on a policy that matches `Pods`/`Deployments` cluster-
   wide can deadlock the cluster on the Kyverno pod's *own* recreation — the same
   class as the ingress-nginx admission-webhook deadlock AGENTS §6.24 documents.

**Fix:** Any Enforce promotion must (a) be namespace/label-scoped, never cluster-
wide match with `Fail`; (b) carry its own positive control proving it does not
block healthy real workloads (the plan says this for the DB gate — extend it to
*every* Enforce promotion); (c) be sequenced as its own PR with a rollback note,
not bundled into "P1 cheap/static, no behavior risk" (Enforce is the opposite of
no-behavior-risk). Add an explicit precondition: confirm Kyverno runs HA
(>1 replica) before any `failurePolicy: Fail`.

### M2 — The EKS `accessConfig.authenticationMode` and node/scaling fields are HARDCODED in the composition, not patched — so the "negative that CONFIG_MAP-only is rejected at author time" (matrix #1) tests a string-equality lint, and the plan should say so rather than implying admission/validation.

`platform-cluster.yaml:319-320` hardcodes `accessConfig: {authenticationMode:
API_AND_CONFIG_MAP}` directly in the MR base — it is not XR-driven and not
patched. So the "negative test that CONFIG_MAP-only is rejected" cannot be an
admission or XRD-validation test (there is no field on the XR to set to
CONFIG_MAP). It can only be a **static lint** asserting the composition's base
contains `API_AND_CONFIG_MAP` (or at least `API`). That is fine and valuable, but
matrix #1's "negative that CONFIG_MAP-only is rejected" implies a runtime
admission rejection that does not exist. Likewise there is no XRD path to inject
a bad authenticationMode, so a "bad-param" live negative is not available here.

**Fix:** Relabel matrix #1's PRE-FLIGHT negative as a **composition-text lint**
(`yq` on `.spec.pipeline[].input.resources[] | select(.base.kind=="Cluster") |
.base.spec.forProvider.accessConfig.authenticationMode` ∈ {API,
API_AND_CONFIG_MAP}), not an "author-time rejection." If the team wants a true
admission negative for authenticationMode, it would require making it an XRD enum
field with an XRD `x-kubernetes-validations` CEL rule forbidding CONFIG_MAP-only
— call that out as a *design change*, not a test.

### M3 — The spoke-XR-Ready trigger: where does the trigger code run, and how does it observe XR Ready, given the spoke kube-API is private-CA and unreachable from the sandbox?

§8 keys the spoke verification off "the spoke EKS XR reaching Ready" and says the
hub→spoke e2e runs "automatically at the end of any spoke `apply-and-verify`/
reconcile-completion." Two mechanism gaps:

1. **The XR that provisions the spoke is a hub object** (XPlatformCluster lives
   on the *hub* cluster; Crossplane on the hub reconciles it). So "XR Ready" is
   observable from the **hub** kube-API — good. But the *hub→spoke e2e* (sync an
   Application, curl the spoke ingress) needs the **spoke** kube-API and the hub
   app-controller's spoke access. The plan says run it "from CI/in-cluster" — but
   §14.2 itself flags this is an *unconfirmed operator dependency* (CI may only
   have `kube-diagnose.yml`-style read paths). So the central spoke backstop is
   gated on an unproven capability. The plan should not list the hub→spoke e2e as
   a committed P5 deliverable while §14.2 lists its prerequisite as unconfirmed —
   that is an internal contradiction.
2. **"reconcile-completion" has no event hook.** §8 correctly notes there is no
   `terraform/spoke` to hang an end-of-bring-up step on. The proposed mechanism —
   "the bring-up that applied the spoke XR sets `expect-full`" — only works if a
   *human/agent-driven `apply-and-verify`* applied the spoke XR. But in a GitOps
   repo the spoke XR is more likely synced by **ArgoCD** from git (AGENTS §6.22),
   in which case there is no `apply-and-verify` invocation to set `expect-full`,
   and the spoke checks fall back to phase-not-applied → auto-skip-green, which is
   the exact silent-skip the plan is trying to kill. The "phase-aware bring-up
   sets expect-full" model assumes an imperative apply that GitOps removes.

**Fix:** Specify the trigger as a **hub-side watch**: a controller/CI step that
watches `XPlatformCluster` (and `XSpokeAccess`) on the **hub** for
`Ready=True` transitions and, on the transition, fires the spoke AFTER-THE-FACT +
(if CI-reachable) the e2e. Drive `expect-full` off the **git-desired state**
(is there a spoke XR committed under `clusters/`?) rather than off "did a human
run apply-and-verify" — so an ArgoCD-synced spoke is still `expect-full`. And
demote the hub→spoke *curl* e2e to "ships when §14.2's CI-spoke-API path is
confirmed," with the hub-side XR-Ready + AccessEntry + ArgoCD `connectionState:
Successful` checks as the always-available substitute.

### M4 — simulate-principal-policy can return false "allowed" because the policy's `Resource` is `"*"` for IAM/RDS/EC2 but scoped (`secretsmanager:...:secret:k8-platform/*`, `route53:::hostedzone/<zone>`) for others — the simulation must pass the correct ResourceArns or it lies in both directions.

§2.3/§4.3 lean hard on `aws iam simulate-principal-policy` as the honest
completeness tool. It is — but only if invoked correctly. Verified in irsa.tf:
IAM (line 86), RDS (107), ACM (134), Route53Read (159) are `Resource = "*"`;
SecretsManager (117) is scoped to `secret:k8-platform/*`; Route53Validation (148)
to `hostedzone/<zone_id>`. `simulate-principal-policy` evaluates per
`--action-names` **and `--resource-arns`**. If the plan simulates SecretsManager
actions with `--resource-arns '*'` (or omits it), the scoped statement will
return **implicitDeny** → a false "the grant is missing" failure; conversely
simulating with a matching ARN when the real Composition uses a non-matching one
hides a real scope bug. Also: simulate-principal-policy does **not** evaluate
SCPs or permission boundaries unless they are attached to the *simulated
principal* and visible — the plan claims it catches "an explicit Deny/SCP/
permissions-boundary elsewhere" (§4.3), which is **only partially true** (SCPs at
the org level are not reflected for a role in a member account via this API in
the general case).

**Fix:** The simulate harness must pass a **per-action `--resource-arns`** drawn
from the same scope the Composition targets (k8-platform/* secret ARN, the
hosted-zone ARN, `*` where the policy is `*`). A unit test should assert the
simulate inputs' resource ARNs match the irsa.tf statement scopes, so a scope
change in irsa.tf forces a simulate-input change. Soften the SCP/boundary claim
to "catches account-attached explicit Denies and boundaries; org SCPs are NOT
fully reflected — those remain a residual."

### M5 — The `route53:*` exemption the plan wants to "convert to an annotated justification" does not exist in irsa.tf; the test's wildcard handling is generic. Minor factual drift that will send an implementer chasing a ghost.

§4.1 note: "the test today *accepts* `route53:*` wildcards in its header — that
exemption must itself become an annotated, reviewed justification." I read
`test_iam_required_actions.sh` fully: there is **no `route53:*` exemption in a
header**. The test's wildcard handling is *generic* — `is_action_granted`
(lines 63-79) accepts `service:*` or `verb*` prefix matches for **any** service,
and the header comment (lines 12-17) uses `route53:*` only as a worked *example*
of the generic rule, not as a special-case exemption. And irsa.tf grants **no**
`route53:*` wildcard at all — Route53 is split into two narrowly-enumerated
statements (lines 141-160). So the plan's instruction points an implementer at a
nonexistent exemption.

**Fix:** Rewrite §4.1 to target the *real* gap: the generic `service:*` /
`verb*` acceptance in `is_action_granted` is the ceiling hole (it would silently
accept a future `iam:*`). The ceiling lint must **reject** broad wildcards in the
*policy*, independent of the floor test's matching leniency. Drop the
"route53:* header exemption" sentence — it describes the wrong artifact.

---

## MINOR

### m1 — `wait-for-claim.sh` and `scripts/irsa_trust_validator.py` are cited but not verified in the plan. The plan asserts the trust validator gives `--all == 0 MISMATCH` as a hard gate (matrix #8); confirm it actually enumerates the *provider* family SA subject (`upbound-provider-family-aws`) and the external-dns SA, since blocker #8 is precisely an SA-name≠subject mismatch. If the validator's SA inventory is hand-maintained it has the same drift risk as the coverage manifest.

### m2 — "v2 connection-secret rejection (AGENTS §6.8)" negative (§6) is well-grounded (the v2 webhook rejects `connectionSecretKeys` on XRDs — AGENTS §6.8 documents the exact message). Good. But note the XRDs in this repo are *already* v2 and presumably already stripped of that field; a negative that applies a doctored XRD with `connectionSecretKeys` is a synthetic-fixture admission test (fine) — make explicit it uses a throwaway XRD fixture, not the live XRDs, or it will fail to even create the fixture.

### m3 — §5 "shared-VPC subnets carry the spoke's `kubernetes.io/cluster/<name>` + `elb`/`internal-elb` tags": for an EKS *managed node group* the cluster security-group/subnet discovery tags matter, but the NLB-provisioning blocker (#9) is specifically the `kubernetes.io/role/elb` (public) / `kubernetes.io/role/internal-elb` (private) tags read by the AWS Load Balancer Controller / in-tree provider. The plan's tag names are slightly loose; pin the exact tag keys/values in the assertion or it will assert the wrong tag and pass while the LB still can't provision.

### m4 — §3.2 "a unit test asserts the on-by-default value ... in any `workflow_dispatch` input default is literally `enabled`": this environment **cannot edit `.github/workflows/*`** (the plan itself relies on this constraint in §3.4). A unit test that *reads* a workflow input default is fine (read-only), but if the intended default lives in a workflow the team can't edit from here, the "flip is a red diff" guarantee is only as strong as the committed-config copy the orchestrator reads. Make the orchestrator's own committed config the single source the unit test asserts, and treat any workflow_dispatch default as advisory.

### m5 — §7.2 enumerates ASM teardown keyed on the run-id prefix on the XR/claim name as primary, label-sweep as defense-in-depth — correct and well-grounded in OI-2026-05-28-1. But note the ASM Composition tags secrets `k8-platform/<XR-uid>` and the SecretsManager IAM scope is `secret:k8-platform/*` (irsa.tf:117). A test that creates a secret outside the `k8-platform/` path prefix will hit AccessDenied on create (not a leak) — so synthetic test secrets MUST use the `k8-platform/` name prefix or the positive test fails for an unrelated reason. Call this out alongside the redaction rules.

### m6 — `tests/integration/run.sh` exit-0-on-all-skip and `rc==2 ⇒ SKIP` (verified lines 26-45) are exactly as the plan describes — the §3 grounding is accurate. The new `tests/live/run.sh` with inverted semantics is sound. One caution: the existing convention is `exit 2 = skip`; the new floor logic must not collide with `exit 2` from a sub-check meaning "skip" when the orchestrator wants it to mean "promoted FAIL under expect-full." Define the exit-code contract explicitly (e.g. reserve a distinct code for expect-full-violation) so a child script's `exit 2` is not silently swallowed as an allowed skip.

---

## NEW flaws introduced by the MERGE (not in any single source plan)

- **N1 (merge):** The plan rejects the probe-pod (§2.1, §13) AND offers a probe-
  pod as fallback identity proof (§2.2.2 option b). The two source ideas
  (security-B's "no probe SA" + security-A's "make identity falsifiable") were
  merged without reconciling that the only *direct* in-band caller-ARN proof is a
  probe-shaped thing. → see C4.
- **N2 (merge):** §1's three-bucket collapse maps "C:T4" to BRING-UP and "C:T3"
  to AFTER-THE-FACT, and §3.5 says the mapping test must require `cheap`→BRING-UP,
  `slow`→AFTER-THE-FACT. But the *cost annotation lives on the resource* (§13
  rejected the separate COST_TIERS file). Where exactly? The compositions have no
  per-MR cost annotation today, and adding one to `crossplane/compositions/*`
  means editing production manifests to carry test metadata — a coupling the
  team may not want. The merge created a derivation requirement (cost-tier from
  resource annotation) with no specified home. Specify the annotation key and
  location, or accept a curated tier registry (and drop the "no separate file"
  purity in this one case).
- **N3 (merge):** §3.4 routes enforcement through `tests/unit/run.sh` and §6.16
  requires `run.sh`↔`unit-tests.yml` sync, but the new gates (coverage,
  skip-baseline, register validation) are *new* `tests/unit/test_*.sh` files that
  must be added to BOTH `run.sh` AND `unit-tests.yml` in the same PR. The plan
  mentions the sync pattern (§3.4 last bullet) but does not flag that the
  catch-all step in `unit-tests.yml` is the *only* sync mechanism this
  environment can guarantee (it can't edit per-step lists in the workflow if
  workflow edits are blocked — wait, unit-tests.yml is editable via normal push?
  Confirm: AGENTS §6.7 lists unit-tests.yml as a light push workflow, and the
  blocked-workflow constraint is about *creating new* workflows / the `workflow`
  OAuth scope. Clarify whether editing the existing `unit-tests.yml` per-step
  list is possible here; if not, the catch-all step is mandatory, not optional).

---

## What finalization MUST NOT weaken

1. **The center holds:** drive the REAL provider controller under its own
   identity (no probe SA assuming the restricted role), `simulate-principal-
   policy` for completeness on the expensive kinds, derived (not hand-maintained)
   coverage gating CI-red at authoring time, the executed-test FLOOR with
   `expect-full` skip→FAIL promotion, reaper-runs-first + remediate-not-report,
   synthetic-secret/redaction. Do not let finalization trade any of these for a
   green-by-default lint suite — that is the disease.
2. **The identity assertion must stay FALSIFIABLE and must be CORRECTED** to
   `source: IRSA` on the AWS `ClusterProviderConfig` + "no static-cred AWS
   ProviderConfig + no AWS_ACCESS_KEY_ID in the provider pod" as the primary,
   in-band, sub-second check. Finalization must not paper over C1 by keeping the
   "InjectedIdentity/IRSA" either-or phrasing — that makes the assertion
   un-failable.
3. **The spike gates everything (§12).** Do not let finalization promote P4 (the
   central behavioral catch) ahead of an end-to-end spike that proves, on the
   live hub, the v2-ported skill descends into composed MRs and the identity
   check actually fires. C2/C3/C4 all converge here: the spike must validate the
   *real* composition structure, the *real* v2 XR ref path, and the *real*
   credentials source — not the plan's current (wrong) description of them.

---

*Reviewer note on method:* every Critical and Major is grounded in a specific
file:line I read this session, not in the plan's self-description. The plan's
architecture is strong; its failure mode is that it describes the repo's
Crossplane/IRSA mechanism from memory of the source plans rather than from the
v2/IRSA reality now in `crossplane/**` and `terraform/management/**`. Fix the
four mechanism facts (IRSA-not-InjectedIdentity, Pipeline-mode derivation, v2
skill, in-band identity proof) and the plan is implementable.
