# PLAN-B — Test Overhaul (k8s administrative-testing expert)

> **Status:** plan only. No code or tests are created by this document.
> **Author persona:** unit + integration testing expert for the *administrative*
> side of Kubernetes — CRDs/operators, controllers, admission webhooks, RBAC,
> GitOps reconciliation, Helm, Crossplane compositions, policy engines.
> **Root problem it answers:** `docs/open-issues.md` OI-2026-06-07-6 —
> *"static assertions masquerade as tests; built resources are never verified
> against the real cloud until a dependent fails."* All 8 auto-012 blockers are
> instances of that one class.

---

## 0. The thesis in one paragraph

The current suite proves *the manifest says X*. It almost never proves *X works*.
The fix is **not** "add a nightly real-AWS job" — that decouples the test from the
change, which is the bug. The fix is a **create-and-verify coupling**: every step
that *creates* a thing is immediately, in the same step, followed by a probe that
the thing **exists and behaves** against the **real cluster / real cloud, under
the real identity** (Crossplane's restricted IRSA role, not admin creds). Static
`yq`/`grep` lints survive — but demoted to *pre-flight lints*, never "the test."
The persona's job is to choose, for each contract, the **cheapest layer that can
still fail for the right reason in the real environment**, and to make the
expensive layers (a 20-minute EKS build) *after-the-fact verifiers* rather than
authoring-time gates.

---

## 1. What exists today (grounded read)

- **`tests/unit/` (~60 scripts):** almost all `yq`/`grep`/`helm template` over
  committed YAML/TF. Strong *lint* coverage (kubeconform, IRSA-trust validator,
  golden-render fixtures, IAM-action presence, kyverno lint). **Zero** of them
  call a live API. This is the layer OI-2026-06-07-6 indicts.
- **`tests/chainsaw/` + `run.sh` + `chainsaw.yml`:** KIND + Crossplane v2 +
  `provider-family-aws`, fake/static creds. Proves *render + admission*. Real-AWS
  scenarios gated behind `CHAINSAW_INCLUDE_REALAWS=1` and, when run, use
  **static/admin creds** — so they *mask* exactly the IRSA-permission gaps that
  bit us.
- **`tests/integration/` (01–13):** live-cluster bash probes (ArgoCD deploy,
  ESO round-trip, ext-dns record, ingress curl, IRSA STS round-trip, XRD claim).
  This is the **right shape** but it is (a) management-cluster-only, (b) not run
  on every bring-up by default with a disable switch, (c) missing the hub→spoke
  flow where 6 of 8 blockers live, and (d) not driven under the restricted IRSA
  identity.
- **`terraform-test.yml` `[mgmt] e2e-verify`:** checks pods + **one** ArgoCD SA.
  Blocker #6 (app-controller SA missing IRSA) slipped through *because it only
  checked argocd-server*.
- **Assets we will lean on, not rebuild:**
  - `crossplane-claim-verify` skill — already does "wait Synced/Ready **and**
    verify the cloud resource exists/healthy." Underused. We make it *required*.
  - `scripts/wait-for-claim.sh` — exact-equality Ready wait with timeout dump.
  - `scripts/irsa_trust_validator.py --all` — SA↔trust-subject fleet sweep
    (directly the blocker-#8 class).
  - `scripts/crossplane-trace.sh`, `scripts/whereami.sh`, `kube-diagnose.yml`
    (read-only live reads), `composition-render.sh` + render-fixtures.

---

## 2. Test taxonomy — six layers, by *when the contract fails*

The persona organizes layers by **lifecycle moment of the failure**, not by tool.
Each contract is assigned to the cheapest layer that fails for the *right reason*.

| # | Layer | Environment | Fails at | Tools | What it can / cannot prove |
|---|-------|-------------|----------|-------|----------------------------|
| **L0** | **Static lint / schema** | local, no cluster | author push | `yq`,`grep`,`kubeconform`,`conftest`,`kyverno test`,`helm template`,`composition-render.sh`,`tflint`,`checkov` | manifest *says* X; schema-valid. **Demoted: never "the test."** |
| **L1** | **Render + admission** | KIND + Crossplane, fake creds | author push (heavy) | chainsaw-on-kind, `kubectl --dry-run=server`, envtest | composition renders; admission webhooks accept/reject; RBAC *shape*. Cannot prove cloud effects. |
| **L2** | **Controller/unit behavior** | envtest / fake clients | author push | envtest (`sigs.k8s.io/controller-runtime`), `kuttl assert`, Helm unit (`helm unittest`) | controller logic, helm precondition/readiness templates, conditional rendering. |
| **L3** | **Live admission + RBAC negative** | **real hub cluster** | bring-up | `kubectl auth can-i --as=...`, apply-as-IRSA-SA, AppProject allow/deny | the *real* webhook + the *real* RBAC reject what they should; AppProject permits the kinds it must. |
| **L4** | **Create-and-verify (cheap resources)** | **real cluster + real cloud, restricted IRSA** | bring-up | `crossplane-claim-verify` skill, `wait-for-claim.sh`, AWS CLI `Describe*`, `argocd app/cluster` API | *we instantiated it on purpose and it actually built & behaves.* IAM/ESO/secrets/DNS/IngressClass/SG. |
| **L5** | **After-the-fact verify (slow resources)** | **real cluster + real cloud** | post-build | AWS CLI against EKS/RDS, `irsa_trust_validator.py --all`, hub→spoke integration | *what we believe we built (EKS spoke, RDS) is actually there and wired.* No on-purpose re-create (too slow). |

**Key persona rule:** L4 vs L5 is decided by **cost**, per user requirement 3 & 4.
If creating-then-destroying the thing on purpose costs < ~3 min and < a few cents
→ **L4 (instantiate + verify, every bring-up)**. If it's a 20-min EKS cluster or a
multi-minute RDS → **L5 (verify the one we already built; do not create a throwaway)**.

---

## 3. The "runs on every bring-up + disable switch + skip-guard" mechanism

This satisfies user requirements 1, 2, 6 (and §6.3 of AGENTS.md).

### 3.1 One entrypoint: `tests/live/run.sh` (the "live unit tests")
A single orchestrator that runs **L3+L4+L5** against whatever cluster the current
kubeconfig/AWS creds point at. It is the live-cluster analogue of "run all unit
tests on every compile." It is invoked:
- automatically at the **end of every `apply-and-verify`** (wired into
  `terraform-test.yml`, replacing the thin `[mgmt] e2e-verify` step — see §8), and
- by developers/CI after any cluster bring-up, and
- by the `crossplane-claim-verify` skill as the per-claim unit.

### 3.2 On by default; explicitly disable-able; **disable cannot silently regress**
- **Default = ON.** `run.sh` runs all discovered live checks unless told otherwise.
- **Disable switch:** environment variable `LIVE_VERIFY=0` (or per-check
  `LIVE_SKIP="eks-spoke,rds"`). Honoring requirement 2.
- **Anti-silent-regression (the load-bearing part):**
  1. Every skip **emits a loud `SKIPPED (reason=...)` line to stdout AND increments
     a skip counter** printed in the summary banner. No silent pass.
  2. A **disable manifest** `tests/live/SKIP_REGISTER.yaml` is the *only* sanctioned
     way to durably disable a check. Each entry requires `reason`, `owner`, and
     `expires` (a date). A **unit test** `test_live_skip_register.sh` (L0, runs on
     every push) FAILS if: any entry lacks a field, any `expires` is in the past, or
     any check is skipped at runtime that is **not** in the register. This makes
     "disabled" a *visible, expiring, reviewed* state — mirrors the existing
     `kubeconform-skip` allowlist discipline (AGENTS.md §6.1) and the
     open-issues-register discipline (§6.18).
  3. CI prints the skip count into the run summary and the verifier workflow
     (§8.4) **fails the PR check if the live-verify skip count increased vs main**
     without a matching `SKIP_REGISTER.yaml` diff. Disabling a check is therefore a
     reviewable diff, never an accident. (Directly honors requirement 2's "must not
     silently regress.")

### 3.3 Skip-guard for genuine environmental gaps
A check **auto-skips (loudly)** when its precondition is structurally absent —
e.g. RDS verify when no spoke exists yet, or any kube-API check from the sandbox
(private CA, AGENTS.md §6.26/§6.27). The guard distinguishes *"not applicable
here"* (auto-skip, logged) from *"disabled on purpose"* (must be in the register).
This prevents the suite from red-flagging in the sandbox while still failing in CI
where the cluster is reachable.

---

## 4. Slow-vs-cheap handling (requirements 3 & 4)

### 4.1 Cheap resources → **L4: instantiate-on-purpose + verify**, every bring-up
For each, the loop is: **apply a throwaway claim/manifest → `crossplane-claim-verify`
/ AWS `Describe*` → assert behaves → delete.** Run under the **restricted IRSA
role** so permission gaps surface. Isolation via the existing per-run-ID prefix
(§6). Candidates (all < a few min, cents):
- **IAM role/policy** (`XSpokeAccess`, IRSA roles): create a probe role via the
  composition path; confirm it exists and the trust policy subject matches the SA
  (this is blocker #8). Negative twin in §5.
- **ESO ExternalSecret / PlatformSecret**: already have `04_eso_secret_round_trip`,
  `11_platform_secret_e2e` — promote into `tests/live/`, run under IRSA.
- **Route53 record** via ext-dns: create an Ingress/Service → assert the record
  appears (`route53-records.sh`) → delete. Catches blocker #8's DNS half.
- **ACM cert, Secrets Manager secret, IngressClass admission** (blocker #7).
- **ArgoCD AppProject permit/deny** (blocker #7): apply an `Application`
  referencing a cluster-scoped `IngressClass` → assert it syncs (positive) and a
  forbidden kind is rejected (negative, §5).

### 4.2 Slow resources → **L5: after-the-fact existence/correctness**, never re-create
EKS spoke (~20 min) and RDS (multi-min) are **not** instantiated by the test
suite. Instead, **after the platform builds them through the normal GitOps path**,
L5 verifies the artifact we believe exists:
- **EKS spoke:** `aws eks describe-cluster` → status ACTIVE, **`accessConfig.authenticationMode` includes API** (blocker #1), AccessEntry for the hub app-controller role exists, OIDC provider tagged (blocker #2), nodegroup healthy; shared-VPC subnets carry the spoke's
  `kubernetes.io/cluster/<name>` + `elb`/`internal-elb` tags (blocker #9 — the NLB
  one); spoke registered in ArgoCD (`connectionState: Successful`).
- **RDS (Keycloak DB):** `aws rds describe-db-instances` → available; the
  `XDatabase` XR `Ready=True`; Keycloak pod reaches it (precondition test, §5).
- **Mechanism:** L5 reads via the AWS CLI + the read-only `kube-diagnose.yml`
  workflow (kube-API is private-CA, AGENTS.md §6.26). No throwaway create.

### 4.3 The boundary is explicit and tested
`tests/live/COST_TIERS.yaml` declares each resource's tier (`cheap`→L4,
`slow`→L5). A unit test asserts every XRD/Composition in `crossplane/` maps to a
tier — so a *new* slow resource can't be added without a human deciding which
verification path it gets. (Prevents the "forgot to verify the new thing" relapse.)

---

## 5. Negative + precondition testing (requirement 5)

Negative tests get **first-class** placement — they are where "we cannot build a
broken thing" is proven, which static lints can never do.

### 5.1 Cannot instantiate with improper/incomplete params (admission + XRD validation)
- **L1 (kind, fast):** for every XRD, a chainsaw/kuttl scenario that applies a
  claim **missing a required field** or with an **out-of-range/enum-violating
  value** and asserts admission **rejects** it with the expected message. The XRD
  `openAPIV3Schema` `required`/`enum`/`pattern` are the contract; this proves the
  *live admission webhook* enforces them (not just kubeconform — AGENTS.md §6.8
  showed schema-accept ≠ webhook-accept).
- **L3 (real hub):** the same negative applies against the real Crossplane
  admission webhook, since v2 webhook logic diverges from the static schema.

### 5.2 RBAC / IRSA negative
- `kubectl auth can-i --as=system:serviceaccount:<ns>:<sa>` matrix: the
  application-controller SA **can** assume its role and act; a stripped SA
  **cannot**. Directly the blocker-#6 class.
- **IRSA trust negative:** a probe SA whose name ≠ the trust-policy subject must
  get `AccessDenied` on `AssumeRoleWithWebIdentity` (blocker #8). Positive twin in
  L4. `irsa_trust_validator.py --all` is the fleet-wide static guard; this is the
  live behavioral proof.
- **Crossplane-IRSA permission negative:** apply a claim that needs an action the
  restricted role lacks → assert the MR goes `Synced=False`/`ReconcileError` with
  an AccessDenied reason **rather than silently never creating** (blockers #2–#5).
  This is the test that converts "invisible until a dependent trips" into a loud
  red. Crucially this must run **under the real IRSA role**, never admin creds.

### 5.3 Component preconditions (unit refuses to start without its dependency)
- **Keycloak must not start if its DB is unavailable** (named in requirement 5):
  - L0/L2: `helm template` / `helm unittest` asserts the Keycloak chart wires an
    init-container / readiness probe / `dependsOn` that blocks startup on DB
    reachability, and that the DB secret contract (host/port/cred keys) matches
    `XDatabase`'s output (extends `test_keycloak_db_secret_contract.sh`).
  - L4/L5 (live): with the DB intentionally absent/unreachable, assert the
    Keycloak pod stays `Pending`/`CrashLoopBackOff` on the DB gate and does **not**
    report Ready — i.e. it fails closed, not open.
- **Generalize:** any component with a hard dependency (ESO→SecretStore,
  ArgoCD app→AppProject, spoke add-ons→cluster registration) gets a
  precondition test that the dependent **refuses to go Ready** when the dependency
  is missing.

### 5.4 Kyverno as runtime negative-policy
For invariants expressible as cluster-resource patterns (e.g. "every IRSA SA must
carry a role-arn annotation," "spoke subnets must carry ELB tags"), add **Kyverno
`enforce` policies** with `kyverno test` cases (L0) **and** a live audit
(`kyverno-violations.sh`, L4). Blockers #6 and #9 each become a standing policy.

---

## 6. Isolation, cleanup, flakiness (the things that make a real-cloud suite survivable)

- **Per-run resource prefix + cleanup trap:** reuse the chainsaw pattern
  (`CHAINSAW_RUN_ID`, `ASM_RUN_PREFIX`, `trap cleanup EXIT INT TERM`) for all L4
  throwaway resources. Names embed run id so parallel CI runs don't collide on the
  shared (ephemeral) account.
- **Cleanup must fail loudly:** AGENTS.md §6.19 — no `|| true` masking. Cleanup
  that depends on succeeding uses `if ! cmd; then echo WARN/FAIL`. A leaked-resource
  sweep (enumerate by run-id prefix) runs at suite end and **reports** leaks.
- **Idempotent waits, not sleeps:** all readiness uses `wait-for-claim.sh` /
  `kubectl wait --for=condition` with bounded timeouts + self-describing dumps.
  No bare `sleep`.
- **Flake policy = the open-issues register, not a retry-til-green:** per §6.18,
  any flake gets an `OI-` entry; we do **not** wrap real-cloud checks in blind
  retries (that hides the failure class we're trying to surface). Where a cloud API
  is *eventually consistent* (Route53, IAM propagation), use a **bounded
  poll-until-true with an explicit consistency budget**, documented per check — not
  an unbounded retry.
- **Cost guard:** L5 never creates; L4 always deletes; a suite-level
  `aws ce`/tag-scan budget check can warn if run-id-tagged spend exceeds a
  threshold (account is ephemeral, but cost/time matter — context).
- **Account-rotation guard:** suite preamble runs `whereami.sh` +
  `aws sts get-caller-identity` and the §8.2 precondition checks; if creds/state
  are stale it **stops with a rotation message** instead of debugging code
  (AGENTS.md §8.1/§8.2). No account-derived value is hardcoded in any test (§8.1).

---

## 7. Coverage matrix — every auto-012 blocker → the layer that now catches it

| # | Blocker (auto-012) | Class | Caught at author/bring-up time by |
|---|--------------------|-------|------------------------------------|
| 1 | EKS `authenticationMode` left `CONFIG_MAP` → AccessEntries impossible | EKS config | **L5** `describe-cluster` asserts mode includes `API`; **L0** lint asserts TF/XRD sets API_AND_CONFIG_MAP; **Kyverno** audit. |
| 2 | Crossplane IRSA missing `iam:TagOpenIDConnectProvider` | IRSA perms | **L4/L5 under restricted IRSA**: provisioning an OIDC-tagging path fails `Synced=False` AccessDenied (loud). **L0** `test_iam_required_actions.sh` extended (stopgap). |
| 3 | missing `iam:UpdateAssumeRolePolicy` | IRSA perms | same as #2 — **L4 negative under real IRSA** + L0 action-presence lint. |
| 4 | missing `iam:GetRolePolicy` | IRSA perms | same as #2. |
| 5 | missing **all `rds:*`** → RDS never provisioned | IRSA perms | **L5** `describe-db-instances` + `XDatabase Ready` (after-the-fact, RDS is slow); **L4 negative** claim under IRSA goes ReconcileError instead of silent-never. |
| 6 | app-controller SA lacked IRSA role-arn annotation (only argocd-server had it) | SA/IRSA wiring | **L3** `auth can-i`/SA-annotation check on **both** SAs; **L0** `test_argocd_controller_irsa.sh` (exists) covers static; **Kyverno enforce** "IRSA SA must carry role-arn"; the §8 e2e-verify now checks both SAs. |
| 7 | platform-spoke AppProject didn't permit cluster-scoped `IngressClass` | AppProject RBAC | **L3** apply an Application using IngressClass → must sync (positive) + forbidden-kind rejected (negative); **L0** `test_platform_spoke_appproject.sh` extended. |
| 8 | ext-dns SA `spoke-external-dns` ≠ trust subject `external-dns` → AssumeRole denied, 0 DNS records | IRSA subject mismatch | **L4** create Ingress → assert Route53 record appears (positive); **L4 negative** AssumeRole denied for mismatched subject; **`irsa_trust_validator.py --all`** fleet sweep (must be `0 MISMATCH`). |
| 9 | shared-VPC subnets not tagged for spoke → NLB never provisioned | resource tags | **L5** subnet-tag assertion in spoke verify; **Kyverno** audit on subnet tags; **L0** lint on the tag-injection composition. |

**The pattern:** every IRSA-permission blocker (2–5,8) is only *faithfully* caught
by running **under the restricted IRSA role** — the single most important change,
because kind/admin-cred chainsaw *masks* this whole class (OI-2026-06-07-6).

---

## 8. CI wiring

> Constraint: this session cannot create/edit `.github/workflows/*`
> (OI-2026-06-05-6). The workflow edits below are authored as **runbook YAML +
> committed scripts**, then applied via the operator / `ext-github` Contents-PUT.
> The *scripts* (`tests/live/run.sh`, etc.) are committable normally and carry the
> logic, so the workflow change is a thin caller — minimizing the un-committable
> surface.

### 8.1 Push-time (light, every push) — unchanged cadence, expanded content
- `unit-tests.yml`: add the new L0 guards (`test_live_skip_register.sh`,
  cost-tier-mapping test, expanded IAM-action / AppProject / dual-SA lints).
  Keep `run.sh` ↔ `unit-tests.yml` in sync (AGENTS.md §6.16).
- `terraform-validate.yml`: add `tflint`/`checkov` if not present.

### 8.2 Heavy author-time (dispatch-before-PR) — unchanged contract
- `chainsaw.yml` stays kind-only, *relabeled in docs as a render/admission
  pre-flight* (not "proof it builds"), dispatched per §6.7/§6.8. Add the L1
  negative-admission scenarios here.

### 8.3 Bring-up verify (the heart of the overhaul)
Replace `terraform-test.yml`'s thin `[mgmt] e2e-verify` with a call to
**`tests/live/run.sh`** at the end of every `apply-and-verify`. This makes the live
suite run **every time the cluster comes up, on by default** (requirement 1). It
runs L3+L4+L5 for whatever phase is present (skip-guarded for absent phases).

### 8.4 A `live-verify` verifier (mirrors `chainsaw-verify`)
A < 5s push-time workflow that (a) confirms the last `apply-and-verify` on the SHA
ran the live suite green, and (b) **fails the PR check if the live-verify skip
count rose vs main without a `SKIP_REGISTER.yaml` diff** (§3.2). This is the
enforcement that "disabled must not silently regress."

### 8.5 The hub→spoke integration job (covers 6 of 8 blockers in one flow)
A dispatch job that, against a live hub with a built spoke, runs the new
`tests/integration/2x_hub_to_spoke_e2e.sh`: spoke registered → sync an app →
`curl https://hello.platform.<domain>` returns 200 → Keycloak Ready against RDS.
This is the end-to-end backstop OI-2026-06-07-6 item 2 asks for.

---

## 9. Phased rollout (lands as stacked PRs, each independently mergeable)

1. **PR-1 — discipline scaffold (no behavior risk):** `tests/live/` skeleton +
   `run.sh` (skip-guard + loud-skip + summary banner), `SKIP_REGISTER.yaml` +
   `test_live_skip_register.sh`, `COST_TIERS.yaml` + its mapping test. Ships the
   *mechanism* for requirements 1/2/6 before any live check exists. Pure-local
   testable.
2. **PR-2 — promote existing integration probes into `tests/live/` as L4/L5** and
   make `crossplane-claim-verify` a *required* step in the docs/skill. Wire
   `run.sh` into `apply-and-verify` (via runbook YAML).
3. **PR-3 — restricted-IRSA harness:** run L4 create-and-verify **as the Crossplane
   IRSA role** (the central fix). Add the IRSA-permission negative tests
   (blockers 2–5,8). Add `irsa_trust_validator.py --all` as a hard gate.
4. **PR-4 — L3 admission/RBAC negatives** (AppProject permit/deny #7, dual-SA #6,
   XRD required-field rejections) + the L1 negative-admission chainsaw scenarios.
5. **PR-5 — slow-resource L5 verifiers** (EKS spoke #1/#2/#9, RDS #5) + Kyverno
   enforce policies for the standing invariants (#6, #9).
6. **PR-6 — hub→spoke e2e** (`2x_hub_to_spoke_e2e.sh`) + the `live-verify`
   verifier workflow (§8.4) + close the `[mgmt] e2e-verify` gaps.

Each PR follows AGENTS.md §6.2 (write the failing test first — for the 8 blockers,
the test must go *red against the pre-fix state*), §6.4 (adversarial subagent
review of the test plan before authoring), and §6.16 (run.sh↔workflow sync).

---

## 10. Tools chosen, and why (persona justification)

- **envtest** (controller-runtime): the right tool for any *controller/operator
  logic* we own — spins a real apiserver+etcd, no cloud, fast. (We mostly compose
  rather than write controllers, so this is targeted, not central.)
- **kuttl / chainsaw against a *real* cluster:** chainsaw's assert/error model is
  already in-repo; the change is *pointing a subset at the real hub under IRSA*,
  not kind. kuttl is the fallback for plain `kubectl apply→assert` cases.
- **`crossplane-claim-verify` skill + `wait-for-claim.sh`:** the canonical L4 unit
  — already does Synced/Ready + cloud existence. Make it mandatory.
- **AWS CLI `Describe*`:** the L5 truth source for slow resources (EKS/RDS/subnet
  tags/OIDC) — reachable when the kube-API isn't (private CA, §6.26).
- **`kubectl auth can-i --as` + AssumeRoleWithWebIdentity probes:** the RBAC/IRSA
  negative engine (#6, #8).
- **Kyverno `test` + enforce + `conftest`:** standing runtime invariants and
  policy unit tests for the tag/annotation classes (#6, #9).
- **`irsa_trust_validator.py --all`:** fleet-wide SA↔subject sweep — exactly #8.
- **Helm precondition/readiness testing** (`helm unittest` + live readiness
  assertions): the Keycloak-needs-DB precondition (requirement 5).
- **terratest:** *considered and deferred* (see §12) — our TF is thin and
  `terraform-test.yml` already does apply-and-verify; terratest would duplicate it.

---

## 11. Assumptions

- The restricted Crossplane IRSA role is assumable by a probe pod/SA we can stand
  up on the hub (needed to run L4 "under the real identity"). If it can only be
  used by the Crossplane controller itself, L4-under-IRSA becomes "apply the claim
  and let the real controller act" rather than a direct probe — still faithful.
- The ephemeral account permits creating/deleting the L4 throwaway resources
  (IAM probe role, ASM secret, Route53 record) within normal quotas.
- `kube-diagnose.yml` (read-only) can be extended/relied on for L5 kube-side reads
  from CI; the sandbox itself cannot reach the kube-API (private CA).
- "Every bring-up" = every `apply-and-verify` of phase 1, plus every spoke build —
  the live suite is phase-aware and skip-guards absent phases.

## 12. Open questions / deliberately out of scope

- **terratest** for the TF layer — deferred; flag if reviewers want TF behavior
  (not just plan/apply) tested independently.
- **Chaos/failure-injection** (kill a provider pod mid-reconcile) — out of scope;
  the precondition tests (§5.3) cover the dependency-missing case, not arbitrary
  fault injection.
- **AWS API rate-limit / throttling behavior** — explicitly out of scope.
- **Multi-spoke / scale** — single spoke is the contract here.
- **Open question:** should L5 EKS-spoke verify run on *every* hub bring-up (the
  spoke may not exist) or only after a spoke build? Plan assumes skip-guard +
  the dedicated §8.5 job; confirm the desired default.
- **Open question:** exact restricted-IRSA assumption mechanism for the L4 probe
  (dedicated probe SA vs reuse the controller path) — pick at PR-3 author time
  with an adversarial-subagent review.
