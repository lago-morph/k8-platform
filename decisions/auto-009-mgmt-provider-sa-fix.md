# Decision brief auto-009 — management provider bootstrap: reconcile the duplicate `provider-family-aws` Provider object

**Run.** auto-009 (mgmt-provider-diagnosis). **Status.** Round 1 (awaiting adversarial wave 1).
**Tracks.** OI-2026-06-06-2 (`docs/open-issues.md`).
**Scope warning.** This edits a **load-bearing bootstrap** path
(`terraform/management/helm.tf` + `crossplane-phase3.tf`) that has now failed
the provider step three runs in a row across two distinct root causes
(OI-2026-06-05-3, -4, and this -2). It will get adversarial review before
anyone applies it. The diagnosis run did NOT change any terraform.

---

## Question

`terraform-test.yml phase=management apply-and-verify` (run `27054926075`, main
`c3a6cb3`) fails at `terraform_data.crossplane_aws_provider` (helm.tf:241): the
`kubectl wait --for=condition=Healthy provider/provider-family-aws --timeout=300s`
never meets the condition, and the post-check then reports
`expected SA upbound-provider-family-aws, got: MISSING`.

The run's own diagnostics dump establishes the shape of the failure
(Observations, quoted in OI-2026-06-06-2):

- **Zero of six AWS provider revisions ever became Healthy** — all sit
  `INSTALLED=True HEALTHY=False`, revisions `RUNTIME=False STATE=Active` at +5m.
- **No provider runtime Deployment or ServiceAccount was ever created** — the
  only deploy/sa in `crossplane-system` are the Crossplane core, rbac-manager,
  and `function-environment-configs`. There is no `provider-*` Deployment.
- **The same package is owned by TWO Provider objects:** `provider-family-aws`
  (declared explicitly in helm.tf) and `upbound-provider-family-aws` (created
  ~6s later as a **dependency** auto-resolved by the four `provider-aws-*` child
  providers in `crossplane-phase3.tf`; Crossplane names the dependency from the
  package's own `metadata.name`).

So the SA is `MISSING` because **no provider runtime exists to own one** — not
because the DRC `serviceAccountTemplate.metadata.name` override was ignored (the
helm.tf comment + the hard-coded error string assert the latter; that is
**excluded** by the evidence — there was no Deployment to attach any SA to).

**Root cause (labelled, §6.17): structural, not timeout.**
*Conclusion:* the bootstrap declares the family package twice under two Provider
object names, which is a package-manager conflict; the wait is keyed on one of
the two contending objects and can never go Healthy.
*Hypothesis (mechanism, not positively tested this run):* the two Provider
objects' revisions contend over installing the same package's CRDs/runtime
(CRD-ownership / "already managed by" deadlock), so neither revision activates a
Deployment. Consistent with all six AWS providers (all transitively depending on
the family package) being stuck while the family-independent core + function
runtimes came up fine. Positive confirmation needs
`kubectl describe providerrevision …` + crossplane controller logs (see
OI "next diagnostic step").

**Why now / why it changed.** The duplicate only exists because PR #145 (commit
`e26b115`, `crossplane-phase3.tf`) added the four child providers. Before #145,
helm.tf's single explicit `provider-family-aws` was the only owner of the
package. #145 introduced the second, dependency-named owner — turning a
working single-owner bootstrap into a two-owner conflict. This is a regression
**introduced by #145's interaction with the pre-existing helm.tf**, not by
either file alone.

## Alternatives (≥2 named options)

**Option A — RENAME the explicit Provider to the dependency name (single object).**
Change helm.tf:208 `metadata.name: provider-family-aws` →
`upbound-provider-family-aws`. The child providers' dependency resolver already
wants exactly that name, so they de-dupe onto the one explicit object instead of
spawning a second. The explicit object retains
`runtimeConfigRef: aws-provider-config`, so the surviving single family Provider
gets the pinned SA + IRSA annotation. Companion edit: helm.tf:256 Healthy-wait
target → `.../upbound-provider-family-aws`. helm.tf:281/:299 (SA poll + gate) and
irsa.tf:140 (`crossplane-system:upbound-provider-family-aws`) already use that
name — no change.
- *Pros:* one Provider object per package (removes the conflict at the source);
  smallest diff; keeps the DRC/IRSA binding exactly as designed; name now matches
  irsa.tf and the SA gate, removing a long-standing naming smell.
- *Cons:* relies on the dependency resolver de-duping a pre-existing
  same-named explicit Provider onto its dependency edge rather than erroring on
  a name collision. **This is the load-bearing assumption and must be
  confirmed** (Crossplane treats an explicitly-created Provider with the
  dependency's name as satisfying the dependency — expected, but verify on a
  live run before trusting it).

**Option B — DROP the explicit family Provider entirely; let the child providers
pull it as a pure dependency, and move the DRC binding onto the dependency.**
Delete helm.tf:205-215 (the explicit `kind: Provider provider-family-aws`). Keep
the DRC `aws-provider-config`. The family package then exists ONLY as the
`upbound-provider-family-aws` dependency. Bind the DRC to it via the child
providers / a `runtimeConfigRef` on the dependency.
- *Pros:* removes the explicit object completely; the family provider is modeled
  honestly as "a dependency of the children we actually use."
- *Cons:* a **dependency-created** Provider object has no place for us to set
  `runtimeConfigRef`/DRC at creation time — Crossplane creates it from the
  package's lock, not from our manifest. Pinning the SA on a dependency-only
  provider in v2 is not a first-class path; risks re-introducing the
  default-hash SA name and breaking IRSA (the exact failure OI-2026-06-05-* was
  built to catch). Higher uncertainty than A.

**Option C — keep two objects, serialize + wait on the dependency one.** Leave
helm.tf as-is but add `depends_on`/ordering so the child providers (and their
dependency family provider) settle first, and point the Healthy-wait at
`upbound-provider-family-aws`.
- *Pros:* smallest conceptual change; no rename.
- *Cons:* does **not** remove the two-owner conflict — it only changes which of
  the two deadlocked objects we wait on. If the conflict hypothesis is correct,
  both stay `HEALTHY=False` and this still hangs. Rejected as not addressing the
  Conclusion.

## Recommended fix + reasoning

**Recommend Option A (rename to the single dependency name), gated on one
live-run confirmation of the de-dupe assumption.**

Reasoning: A is the only option that (1) eliminates the duplicate-owner conflict
named in the Conclusion, (2) keeps the DRC→SA→IRSA chain on a first-class
explicit Provider object (so the OI-2026-06-05-* SA-pinning guarantees still
hold), and (3) aligns the Provider object name with the name irsa.tf and the SA
gate already expect — collapsing three names into one. Option B is more
"correct" topologically but moves SA-pinning onto an unsupported dependency-only
path; Option C doesn't fix the root cause.

The one risk in A — does Crossplane de-dupe an explicit Provider named
`upbound-provider-family-aws` against the children's dependency edge, or error on
collision? — is cheap to settle: it is directly observable on the next
apply-and-verify run (the `kubectl get providers` diagnostics already in helm.tf
will show one object vs. two). Do NOT merge A on reasoning alone; confirm
single-object + Healthy=True on a live run first.

**Companion guardrail (apply with A regardless of option):** the hard SA gate's
failure message (helm.tf:301-305) currently asserts "DRC override appears
ineffective," which mis-attributed this failure for a whole run. Broaden it to
also dump `providerrevision` `status.conditions` on failure so the next
provider-stall is diagnosed from the log without a re-run.

## Downstream impact

- **terraform/management/helm.tf** — Provider name + wait target change. Forces a
  re-apply: the manifest is hashed into `triggers_replace`
  (`sha256(local.crossplane_aws_provider_manifest)`, helm.tf:227), so the rename
  re-runs the provisioner automatically. Also bump the
  `provisioner-command-…` sentinel (helm.tf:238) since the wait command body
  changes.
- **crossplane-phase3.tf** — unchanged under Option A (the child providers keep
  pulling the family dependency; they now satisfy it from our renamed object).
- **terraform/management/irsa.tf:140** — already
  `crossplane-system:upbound-provider-family-aws`; unchanged. The rename makes
  the runtime SA finally match this trust subject, which is the whole point of
  the SA-pinning design.
- **Chainsaw / downstream claims** — once the family + child providers go Healthy
  with the correctly-named IRSA SA, ASM Secret MRs and the XPlatformCluster
  Composition can actually reconcile; this unblocks the phase-2/phase-3 e2e that
  has been gated behind the provider bootstrap.
- **No application-data or state-shape change** — this is a control-plane
  bootstrap object rename; no managed-resource external-names move.

## Rewind point

- **Pre-change main:** `c3a6cb3` (the failing run's SHA). Revert target if the
  rename regresses.
- **Last-known provider-step-green:** run `26621556820` (2026-05-29, per
  OI-2026-06-05-2) — that build predates PR #145, i.e. predates the second
  Provider object, which is consistent with the structural conclusion.
- **Atomic revert:** the fix is a 2-line rename + 1 sentinel bump in helm.tf.
  Reverting that commit restores the exact failing-but-known state; the DRC,
  irsa.tf, and crossplane-phase3.tf are untouched, so there is no multi-file
  unwind. If A's de-dupe assumption proves false on the confirmation run, abandon
  A and fall back to evaluating Option B before any merge — do not iterate A
  blindly.

---

### Adversarial-review checklist (for the reviewer)

1. **Is the de-dupe assumption (A's load-bearing premise) actually true in
   Crossplane v2.5.0?** If an explicit Provider sharing a dependency's name
   causes a collision error instead of satisfying the edge, A is wrong — demand
   the live-run `kubectl get providers` evidence showing ONE object.
2. **Is the structural conclusion right, or could the providers be stuck for an
   independent reason (image pull, RBAC, runtime config)?** The mechanism is
   labelled a hypothesis; the "next diagnostic step" (describe revisions + core
   logs) must be run to convert it to a conclusion before trusting that the
   rename alone fixes it. If the revisions are stalling on image pull, the rename
   is necessary-but-insufficient.
3. **Does removing one of the two objects ever orphan a half-installed
   revision** that the package manager won't garbage-collect, leaving a stuck
   `providerrevision`? Confirm a clean fresh-cluster apply, not just an in-place
   edit of the broken cluster.

---

## Round-1 adversarial review

Three reviewers attacked the Option-A plan. **All three returned
accept-with-amendment** — none rejected the rename, each demanded a specific
guardrail before a live apply.

### Reviewer verdicts (all accept-with-amendment)

- **Reviewer 1 — ordering.** Accept the rename, but the rename alone does not
  *guarantee* de-dupe if the children apply in the same unordered terraform
  batch and create the dependency Provider before the explicit object exists.
  *Amendment:* add `depends_on = [terraform_data.crossplane_aws_provider]` on
  the four phase-3 child providers so the family object is applied (and reaches
  Healthy) first; the children then resolve their dependency to the existing
  object rather than racing to create a rival.
- **Reviewer 2 — diagnostics.** Accept, but the current SA-gate failure message
  mis-attributes a runtime-never-stood-up failure to "DRC override ineffective"
  (it burned a whole run on the wrong hypothesis). *Amendment:* broaden the
  failure path to dump `providerrevision` (get + describe), `lock lock -o yaml`,
  `crossplane` controller logs (tail 120), and `provider,deploy,sa --show-labels`
  — each step guarded so one failure doesn't abort the dump — so the next stall
  is diagnosed from the log without a re-run.
- **Reviewer 3 — name alignment + one-Provider assertion.** Accept, but the
  chainsaw harness installs its OWN `provider-family-aws` Provider and waits on
  it; leaving it un-renamed lets the harness and terraform drift on the object
  name. *Amendments:* (a) rename the harness Provider + its `kubectl wait`
  target to `upbound-provider-family-aws`; (b) add a positive assertion that
  exactly ONE Provider owns the family-aws package (count Providers whose
  `spec.package` matches `provider-family-aws`; warn loudly if >1) so a
  re-introduced duplicate is visible in the log immediately.

### Gate merge

All reviewers converged on the same merge gate: **ship the rename, but do not
merge on reasoning alone** — the load-bearing de-dupe assumption (does an
explicit Provider sharing the dependency's name satisfy the edge, or collide?)
must be confirmed on a **live apply-and-verify** run showing exactly one family
Provider object reaching `Healthy=True` before merge.

### Final decision

**Ship rename + ordering + diagnostics** (Option A plus all three amendments):

1. Rename the explicit Provider `provider-family-aws` → `upbound-provider-family-aws`
   in `helm.tf`, keeping `runtimeConfigRef: aws-provider-config`; retarget the
   Healthy-wait.
2. Add `depends_on` on the phase-3 child providers so they apply after the
   family Provider.
3. Broaden the SA-gate failure diagnostics and add the one-Provider-owner
   assertion.
4. Rename the chainsaw harness Provider + wait target to match.

**Live-validate before merge:** dispatch `terraform-test.yml phase=management
action=apply-and-verify` against this branch; confirm one family Provider
object, `Healthy=True`, and the pinned `upbound-provider-family-aws` SA present,
before merging. Reviewer 2's hypothesis-vs-conclusion point (the package-manager
deadlock mechanism is still a hypothesis until the revision describe + controller
logs confirm CRD-ownership contention) is now answered automatically: if the
rename does NOT fix it, the broadened failure dump captures exactly that evidence
on the validating run.

---

## Live validation 1 (run 27055996205)

The `management apply-and-verify` validation run on this branch **FAILED**, but
the broadened failure diagnostics added in the round-1 fix captured the decisive
evidence and **CONFIRMED the root cause** — it is no longer a hypothesis. The
package-manager `Lock` condition dumped by the SA-gate failure path read:

```
reason: DependencyResolutionFailed
message: 'cannot build DAG: node xpkg.upbound.io/upbound/provider-family-aws already exists'
```

and the diagnostics showed BOTH
`provider.pkg.crossplane.io/provider-family-aws` AND
`provider.pkg.crossplane.io/upbound-provider-family-aws` present
(`INSTALLED=True`, `HEALTHY=False`, same package, ~48m old).

This **positively confirms** the mechanism that round-1 review left labelled as a
hypothesis (item 2 of the adversarial checklist; Reviewer 2's point): the two
Provider objects both own `xpkg.upbound.io/upbound/provider-family-aws`, which
makes the package-manager Lock's dependency DAG **unbuildable**
(`already exists`) → no provider runtimes are ever stood up → no Deployment → no
ServiceAccount → the SA gate reports `MISSING`. The structural Conclusion (§6.17)
and Option A's premise (the rename to a single object is the right fix) are both
vindicated.

**Why the rename could not take effect in-place.** The validating run was on a
NON-fresh (wedged) cluster: the OLD-named `provider-family-aws` object created by
the *first* failed run (27054926075) **lingered**. A plain
`kubectl apply` of the renamed `upbound-provider-family-aws` Provider does NOT
prune the stray old object — so both co-owned the package and the DAG stayed
unbuildable. The rename is correct for a FRESH cluster but is
necessary-but-insufficient on a wedged one. This is exactly the orphan-revision
concern raised in adversarial-review checklist item 3.

### Refinement added (orphan cleanup — self-healing in place)

`terraform/management/helm.tf`, in the `terraform_data.crossplane_aws_provider`
provisioner, now runs an **idempotent pre-apply cleanup** of the stray OLD-named
Provider BEFORE applying the renamed one, so the fix self-heals a wedged cluster
without a `terraform destroy`:

```sh
kubectl delete provider.pkg.crossplane.io provider-family-aws --ignore-not-found --wait=false
# then wait until it (and its ProviderRevision) is actually gone so the Lock can rebuild the DAG:
for i in $(seq 1 30); do kubectl get provider.pkg.crossplane.io provider-family-aws >/dev/null 2>&1 || break; sleep 2; done
```

- `--ignore-not-found` makes it a **no-op on a fresh cluster** (no regression to
  the clean-install path); it only acts when the orphan is present.
- It runs on **every** provisioner invocation (the provisioner re-runs via
  `triggers_replace`; the sentinel was bumped to
  `provisioner-command-2026-06-06-orphan-cleanup` to force the re-run).
- POSIX `/bin/sh` (no bashisms; gated by the pre-chainsaw audit).
- All round-1 changes are retained: the rename, `runtimeConfigRef` preserved,
  retargeted Healthy-wait, child-provider `depends_on`, broadened failure
  diagnostics, and the one-Provider-owner assertion.

**Status:** re-validating with the orphan-cleanup refinement. The deletion lets
the Lock rebuild the DAG cleanly, after which the single renamed Provider should
go `Healthy=True` and stand up the runtime Deployment + pinned
`upbound-provider-family-aws` SA.
