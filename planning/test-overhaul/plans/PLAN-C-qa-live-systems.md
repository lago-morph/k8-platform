# PLAN-C — Test Overhaul for a Live-Cloud Control Plane

**Author persona:** QA / test-architecture lead specializing in systems that
depend on external live systems (cloud-provider APIs, managed services you
cannot fully mock).

**Status:** PLAN ONLY. No code, tests, workflows, or fixtures are created or
edited by this document. Everything below is a proposal.

**Scope note for the reader:** I deliberately reason in general,
transferable QA terms (the test pyramid, hermetic vs. integration
boundaries, resource lifecycle, idempotency, flakiness control, contract
testing, gating, observability) and then map them onto this system's
Kubernetes/Crossplane/AWS reality. Where a mechanism needs a Kubernetes or
Crossplane specialist to nail down, I flag it explicitly with **[K8S-SPECIALIST]**.

---

## 0. The one-sentence diagnosis

The existing test estate is strong on **authoring-time static assertions**
(unit, kubeconform, Kyverno lint, composition-render fixtures) and on a
**hermetic dynamic layer** (chainsaw against `kind` + a fake/stub AWS with
admin creds), but it has a **structural blind spot**: nothing asserts that a
*real* resource was *actually built* by the *real restricted controller
identity*, and the one place that almost does (`terraform-test.yml`'s
`e2e-verify`) verifies shallowly and runs too rarely. Every one of the eight
recent live failures lives precisely in that gap.

This plan closes the gap with three moves:

1. **Promote the existing live verification helper** (`crossplane-claim-verify`
   skill + `scripts/wait-for-claim.sh` + the cloud-side `Describe*` checks)
   from "underused, optional" to the **default, always-on dynamic gate that
   runs on every bring-up**.
2. **Add a real-identity dimension** to dynamic tests: instantiate resources
   under the *restricted controller role*, not admin, so permission/identity
   gaps surface at authoring time instead of in production.
3. **Wrap the whole thing in an on-by-default / explicitly-disable-able /
   anti-silent-regression mechanism** so the live suite is to a bring-up what
   `make test` is to a compile.

---

## 1. What exists today (grounding — verified by reading the repo)

| Layer | Location | Environment | What it proves | Honest limitation |
|---|---|---|---|---|
| Unit | `tests/unit/test_*.sh` | local shell, no AWS/cluster | helm value contracts, IAM-policy completeness, IRSA wiring, XRD field shape | proves config *says* X, not that X got built |
| kubeconform | `tests/unit/test_kubeconform_manifests.sh` | local | manifest schema validity | static; webhook can still reject (ADR-0001) |
| Composition render | `crossplane/xrds/*/render-fixtures/` + `scripts/composition-render.sh` | local | Composition renders to golden output | dry-run; no real provider, no real cloud |
| Kyverno audit | `policies/audit/*.yaml` | in-cluster, continuous | runtime drift from any source | only catches what's already in-cluster |
| Chainsaw | `tests/chainsaw/**` | `kind` + Crossplane + **provider stub / admin creds** | XRD/Composition/Claim logic, retry/timeout flows | **fake cloud, admin identity** — never sees real provisioning or restricted-permission failures |
| Integration | `tests/integration/NN_*.sh` | **live mgmt cluster + real AWS** | real IRSA STS, ESO round-trip, ExternalDNS→Route53, Crossplane→S3 | strongest layer, but invoked rarely and gated weakly |
| e2e-verify (CI) | `terraform-test.yml` `[base]`/`[management] e2e-verify` | live AWS, post-apply | cluster ACTIVE, pods Running, one IRSA annotation present, one DNS record | **shallow** — existence-of-a-few-things, not behavior, not the restricted path |
| harness self-test | `tests/e2e/`, `phase=test` | read-only AWS / gate logic | bootstrap side-effects, gate matrix | not the provisioning path |

**Reusable assets the plan leans on (do not rebuild these):**

- `scripts/wait-for-claim.sh` — hardened wait primitive; exact-equality on
  `Ready=True`, unconditional `exit 1` + auto-dump on timeout (defends the
  PR #59 / #67 silent-PASS classes). This is the canonical wait.
- `crossplane-claim-verify` skill — already encodes the
  "wait for Synced/Ready → descend into managed resources → **independently
  check the real cloud resource via `aws … describe`**" loop. This is the
  underused verification helper the brief refers to. The plan's job is to
  make calling it *mandatory and automatic*, not optional.
- Isolation pattern — `RUN_ID` unique prefix + `add_cleanup`/`trap EXIT` in
  `tests/integration/lib/test-lib.sh`; `CHAINSAW_RUN_ID` + ASM-prefix cleanup
  in chainsaw. Per-run isolation + guaranteed teardown already exists; reuse
  it verbatim.
- Bug-class registry in `ai/TESTING-PLAN.md` — the traceability matrix to
  extend.

---

## 2. Test taxonomy mapped to this live-system reality

I keep the classic pyramid but add an axis the brief demands: **identity**
(admin vs. restricted) and **fidelity** (fake cloud vs. real cloud). The
blind spot is the entire "real cloud × restricted identity" cell.

```
                 fake cloud / kind            real cloud (AWS)
              ┌───────────────────────┬──────────────────────────────┐
 admin creds  │ T1 chainsaw (today)   │ T3 integration (today, admin- │
              │ render fixtures       │    ish creds via CI secrets)  │
              ├───────────────────────┼──────────────────────────────┤
 restricted   │ T2 chainsaw-as-       │ T4 LIVE-VERIFY  ← THE GAP     │
 controller   │    controller-role    │   (after-the-fact existence + │
 identity     │    (NEW, optional)    │    instantiate-under-real-role)│
              └───────────────────────┴──────────────────────────────┘
 static, no cluster:  T0 unit / kubeconform / Kyverno-lint / render-diff
```

The five test *tiers* the overhaul standardizes on:

- **T0 — Static authoring-time** (keep as-is, extend). Fast, hermetic, runs
  on every push. Catches structural/shape bugs.
- **T1 — Hermetic dynamic** (keep). chainsaw on `kind`. Catches Composition
  *logic* in seconds without burning real cloud quota.
- **T2 — Hermetic dynamic, restricted-identity simulation** (NEW, small).
  Run a subset of chainsaw / a dedicated check where the provider is wired
  with a credential whose policy is the *restricted controller policy*, not
  admin — even against the stub — so a *missing IAM action* surfaces as a
  provider `AccessDenied` in `kind`. **[K8S-SPECIALIST]**: whether the AWS
  provider stub honors restricted creds faithfully enough to be worth it, or
  whether this is better done purely at T4, is an open question (see §11).
- **T3 — Live existence/correctness** (the brief's requirement #3 + #4-part-A).
  After a real apply, independently verify the real resource exists and is
  healthy. This is the deepened `e2e-verify` + `crossplane-claim-verify`.
- **T4 — Live instantiate-and-behave under the real restricted identity**
  (the brief's requirement #4-part-B + #5). On purpose, create a resource via
  a claim and verify it *behaves* (round-trips, authenticates, serves), under
  the *real controller role*, plus negative tests that creation *fails* with
  bad parameters / missing preconditions.

The two new live tiers (T3 deepened, T4 new) are where the eight failures get
caught.

---

## 3. The headline requirement: "live unit tests on every bring-up"

The brief's requirements #1, #2, #6 ask for a live-system equivalent of
"run all unit tests on every compile": on by default during development,
explicitly disable-able, never silently disabled, coupled to the change (not
deferred to a nightly).

### 3.1 The bring-up gate ("live preflight + postflight bundle")

Define a single entry point — call it the **live bundle** — that runs as part
of every `apply-and-verify`. It is to a bring-up what `tests/unit/run.sh` is
to a push. Concretely it is an orchestrator (proposed
`tests/live/run.sh`, mirroring `tests/integration/run.sh`'s pass/fail/skip
tabulation) that runs, in order:

1. **Preconditions** (cheap, abort early): `scripts/whereami.sh --json`,
   `aws sts get-caller-identity`, state bucket exists, cluster reachable.
   This is the §10.1 environmental-precondition discipline made a hard gate so
   a rotated-account false-negative can never masquerade as a code failure.
2. **T3 existence/correctness** for everything the phase built (deepened
   `e2e-verify` + per-resource cloud `Describe*`).
3. **T4 instantiate-and-behave** for the non-slow resources, under the
   restricted controller identity.
4. **T4-negative** preconditions/boundary tests.
5. **Cleanup verification** — assert the per-run resources were torn down
   (no orphan leak; see §6).

The existing §6.3 discipline ("run the full bundle after every fresh
apply-and-verify") already exists as a *human/agent* rule. **This plan turns
that rule into an enforced workflow step** so it cannot be skipped by
forgetting.

### 3.2 On-by-default + explicit disable + anti-silent-regression

This is the most important mechanism in the plan; spell it out precisely.

- **On by default.** The live bundle runs whenever `action=apply-and-verify`
  or `action=verify` is dispatched. No flag needed to turn it *on*. The
  default value of the disable switch is "enabled".
- **One explicit switch.** A single workflow input + env var, e.g.
  `LIVE_BUNDLE=enabled|disabled` (default `enabled`). Disabling requires a
  deliberate act and the value is echoed loudly in the run header and the PR
  summary comment ("⚠ LIVE BUNDLE DISABLED for this run by <who/why>").
- **Anti-silent-regression guard (the load-bearing part).** Disabling must
  never be free or quiet. Three independent guards, because a single guard
  rots:
  1. **Reason-required.** `LIVE_BUNDLE=disabled` is rejected unless a
     companion `LIVE_BUNDLE_REASON` is non-empty. No reason ⇒ the workflow
     *fails*, not silently proceeds. (Mirrors AGENTS.md §6.24: never weaken a
     check to go green.)
  2. **Per-resource skip accounting.** The bundle distinguishes PASS / FAIL /
     **SKIP**, like `tests/integration/run.sh` does. Every SKIP prints *why*
     and is counted. A **skip budget**: if skips exceed a threshold (or any
     resource the phase claims to have built is skipped), the bundle exits
     non-zero. "Everything skipped" can never read as green.
  3. **Coverage manifest cross-check** (the durable anti-rot guard). A
     committed manifest (`tests/live/coverage.yaml`) enumerates, per phase,
     every resource type the phase provisions and which live test (T3/T4)
     defends it. A unit test (`tests/unit/test_live_coverage.sh`, runs on
     every push) asserts: (a) every resource type the phase's Terraform /
     Compositions create has a matching live-test entry, and (b) every
     live-test entry maps to a test that actually exists. A new resource with
     no live test ⇒ **CI red at authoring time**. This is the mechanism that
     stops "disabled" (or "never written") from silently regressing — it
     makes *absence of coverage* a first-class failure, the same way
     `test_live_coverage` would have caught the "load balancer never got
     created because the test for it was never written" class.

  **[K8S-SPECIALIST]** input wanted on guard 3's source-of-truth extraction:
  deriving "what resources does this phase create" from Terraform plan JSON +
  Crossplane Composition `resources[]` is mechanical but provider-specific;
  a specialist should confirm the enumeration is complete (e.g. resources
  created as side effects).

### 3.3 Coupled to the change, not a nightly

The bundle runs in the same dispatch that does the apply (`apply-and-verify`),
and the relevant slice runs again on `verify` (cheap, no Terraform). It is
**not** a separate scheduled job. This satisfies requirement #6: verification
is attached to the act of bringing the thing up, exactly as a unit suite is
attached to a compile. The cost discipline in §5 is what makes "every
bring-up" affordable.

---

## 4. Mapping each requirement to a concrete test type

| Req | Requirement (paraphrased) | How this plan satisfies it |
|---|---|---|
| 1 | Live equivalent of "all unit tests on every compile"; on by default | §3.1 live bundle runs inside every `apply-and-verify`; default `LIVE_BUNDLE=enabled` |
| 2 | Disable-able, not disabled now, no silent regress | §3.2 single switch defaulting on + reason-required + skip-budget + coverage-manifest unit test |
| 3 | Slow resources (cluster): verify *after the fact* | §4.1 T3 existence/health checks for EKS/RDS post-apply; **no** instantiate-on-purpose for the 20-min cluster |
| 4 | Everything else: after-the-fact **and** instantiate-and-verify-behavior | §4.2 T3 + T4 for secrets, IAM, DNS, certs, ingress, apps |
| 5 | Negative tests + precondition enforcement | §4.3 T4-negative: bad-param rejection, and health-gate tests (auth service must not start without its DB) |
| 6 | Always-on unit discipline, verification coupled to change | §3.3 in-dispatch, not nightly; §7 CI gating |

### 4.1 Slow / expensive resources — after-the-fact only (Req 3)

The single most expensive op is creating a compute cluster (~20 min); RDS is
~5–10 min. For these we **do not** spin up a fresh one per test run — that
would blow the time/cost budget on an ephemeral account. Instead, **T3
after-the-fact verification** against the cluster/DB the bring-up already
created:

- **Spoke/compute cluster:** `aws eks describe-cluster` → `status=ACTIVE`;
  nodegroup desired==actual and instances `Running`; **cloud-network tags
  present** on the VPC/subnets the cluster and its load balancer depend on
  (this is exactly the missing-tag failure that stopped a load balancer ever
  being created — see §8 row 8). OIDC provider exists; the cluster's IRSA
  trust path resolves.
- **Database (RDS):** `describe-db-instances` → `available`, correct engine
  version, encryption on, in the expected subnet group, reachable from the
  cluster's security group (topology check, not a live connect from CI).

These extend the existing `[management] e2e-verify` step, which today only
checks ACTIVE + pods-running + one IRSA annotation + one DNS record. The
deepening is: **per-resource, tag-aware, and identity-aware** rather than
"a few things exist".

### 4.2 Everything else — existence AND instantiate-and-behave (Req 4)

For seconds-to-minutes resources, do both halves:

- **T3 after-the-fact:** the resource the bring-up created exists/healthy
  (IAM role + its attached policy + its trust policy; ACM cert `ISSUED`; DNS
  record present; secret materialized).
- **T4 instantiate-and-behave under the restricted controller role:** create
  a *throwaway* instance via a claim (unique `RUN_ID` prefix), prove it
  *behaves*, then guaranteed-cleanup. The pattern already exists in
  `tests/integration/11_platform_secret_e2e.sh` (apply XR → wait → ASM secret
  exists → put value → ESO materializes K8s Secret → rotate → delete → assert
  teardown). Generalize that shape to each XRD:
  - **PlatformSecret:** the existing #11 flow — *behavior* = ESO round-trip +
    rotation + cleanup.
  - **IAM role claim:** create → assume the role / call a permitted action →
    confirm success AND confirm a *non*-permitted action is denied (proves the
    policy is scoped, not just present).
  - **DNS record claim:** create → record resolves to expected target.
  - **Ingress/load-balancer:** create a minimal app+ingress → the LB is
    actually provisioned (the missing-tag bug) → curl returns 2xx/3xx.
  - **App identity (e.g. Keycloak SA):** the app's identity name **matches**
    the policy's expected principal and it can actually act (this is the
    name-mismatch silent-no-op failure, §8 row 4). The existing
    `scripts/irsa_trust_validator.py --all` is the static half; T4 adds the
    *live* "it can actually call something" half.

  **The key differentiator vs. today:** these T4 tests run with the
  **restricted controller identity**, not the admin CI key. That is what makes
  "missing IAM permission" / "missing permission binding" / "default that
  blocks the trust mechanism" surface here instead of in production. See §9
  for how to obtain the restricted identity in CI/in-cluster.

### 4.3 Negative & precondition tests (Req 5)

Negative testing is first-class, not an afterthought — these are the failures
that hide best.

- **Bad-parameter rejection (T4-negative).** Apply claims with
  improper/incomplete params and assert they are **rejected** (admission/
  webhook/validation error) or that the composite goes `Synced=False` with a
  specific reason — *not* silently accepted. Examples: missing required field,
  out-of-range value, a name that violates the policy principal contract,
  an instance type outside the account whitelist. The test *fails if the bad
  claim succeeds*. This is the inverse of the render-fixture tests and catches
  the "default left at a value that blocks the trust mechanism" class by
  asserting the safe value is required.
- **Precondition / health-gate (T4-precondition).** Assert a unit refuses to
  start when its dependency is absent. The brief's example — *the auth service
  (Keycloak) must not start if its database is unavailable* — becomes a test:
  with the DB made unavailable (or its secret withheld) in an isolated test
  namespace, the auth deployment must stay `NotReady` / crash-loop with a
  clear reason and must **not** report healthy. The contract is "fails closed,
  loudly", and we verify it fails closed.
  - Two implementation routes, both worth having; **[K8S-SPECIALIST]** to
    choose primary: (a) a Kyverno/admission policy that *blocks* the auth
    workload unless a readiness signal for the DB exists (catches it at admit
    time, continuously); (b) a live T4 test that withholds the DB and asserts
    non-readiness (catches the actual runtime behavior). I recommend both:
    (a) as the always-on continuous guard, (b) as the bring-up proof that (a)
    plus the app's own startup probes actually behave.
- **Negative IAM (T4-negative under restricted identity).** Assert the
  controller *cannot* do things outside its scope — proves least-privilege is
  real, and pairs with the positive "can do its job" test so a future
  over-broad policy is also caught.

---

## 5. Cost / time budgeting and parallelization

The account is ephemeral and cost/time matter; real calls have latency and
transient failures. Budget the bundle so "every bring-up" stays affordable.

### 5.1 Tier the bundle by cost, gate by phase

- **Cheap, always:** T0 (push), preconditions, T3 existence checks (seconds —
  they are `Describe*` API calls).
- **Medium, per-bring-up:** T4 instantiate-and-behave for seconds-to-minutes
  resources (secret/IAM/DNS/cert/ingress). Budget target: the whole T4 set
  under ~10 min wall-clock by parallelizing (see 5.2).
- **Expensive, never-recreate-in-test:** the compute cluster and the DB are
  verified after-the-fact only (T3). We *never* create a throwaway cluster in
  the bundle. This is the single biggest cost lever and is exactly why Req 3
  says "verify after the fact" for slow resources.

### 5.2 Parallelization with isolation

- T4 tests are independent (distinct resource types, distinct `RUN_ID`
  prefixes) ⇒ run them concurrently. The orchestrator should fan out (bounded
  concurrency, e.g. 4) rather than the strictly-serial loop in
  `tests/integration/run.sh`. Concurrency is safe *because* per-run unique
  naming + per-test cleanup already exist.
- Respect account quotas as a hard cap: the EC2 ceiling is **9 concurrent
  instances** (`ai/testing-guidelines.md §1`). T4 tests that create
  instance-backed resources must stay within remaining headroom after the
  cluster/DB are up. The orchestrator should **query remaining quota and
  refuse to over-provision** (fail-closed) rather than hit a mid-test cap.
  **[K8S-SPECIALIST]/cloud:** confirm the exact instances-in-use math for the
  current topology (mgmt nodes + NAT + any spoke).
- **Time budget board:** publish per-tier wall-clock targets and the measured
  actuals in the PR summary comment, so budget regressions are visible
  (observability, §10). Targets (initial, tune after first runs): preconditions
  <30s; T3 <2min; T4 <10min; total live bundle <15min on top of the apply.

### 5.3 Cost guardrails

- **No fresh cluster/DB per test** (above).
- **Reuse the bring-up's cluster/DB** for T4 app/identity tests; create only
  the small, fast resources per test.
- **Guaranteed cleanup** (next section) so an aborted run doesn't strand
  billable resources on the ephemeral account.

---

## 6. Resource lifecycle, cleanup, idempotency

- **Unique per-run naming.** Reuse `RUN_ID` (integration) / `CHAINSAW_RUN_ID`
  (chainsaw) prefixes verbatim. Every T4-created resource carries the prefix
  and a common label (`test.k8-platform/live=true`) for sweep-ability.
- **Guaranteed teardown.** Reuse `add_cleanup` + `trap EXIT`. **Do not** use
  `|| true` to mask cleanup failures (AGENTS.md §6.19) — a failed cleanup must
  surface, because a stranded resource on an ephemeral account is both a cost
  leak and a contaminant for the next run.
- **Cleanup *is a tested assertion*, not best-effort.** The bundle's final
  step asserts zero residual resources match `test.k8-platform/live=true` with
  this `RUN_ID` (the §3.1 step 5). A leak fails the run.
- **Orphan sweeper** (defense in depth, given account rotation). A
  pre-bring-up sweep deletes any `test.k8-platform/live=true` resources older
  than N hours from a previous crashed run, before the new bundle starts.
  (There is prior art in the spec backlog, `SPEC-LC5-cleanup-orphans.md` —
  align with it; **[K8S-SPECIALIST]** to confirm the cross-resource sweep is
  complete for AWS resource types created out-of-band by Crossplane.)
- **Idempotency.** Every T4 test must be safe to re-run: create-if-absent
  semantics on the namespace/claim, and teardown that is a no-op when the
  resource is already gone. The bundle should be runnable twice back-to-back
  with identical results — add a CI lane that does exactly that occasionally
  to catch idempotency regressions.

---

## 7. Flakiness, retry, and timeout strategy

Real cloud calls have latency and transient failures; flaky live tests are
worse than no tests because they train people to ignore red.

- **One canonical wait.** All waits go through `scripts/wait-for-claim.sh`
  (exact-equality on `Ready=True`, unconditional timeout failure + auto-dump).
  Bespoke `until kubectl get | grep True` loops are banned (SPEC-S7). For
  non-claim waits, the `wait_for` helper in `test-lib.sh` is the equivalent.
- **Distinguish transient from real.** Wrap *cloud API* calls (not the
  resource's readiness) in a small bounded retry-with-backoff for the known
  transient classes only (throttling, eventual-consistency 404 on
  first-read), and **never** retry an assertion failure. Eventual consistency
  (e.g. ASM first-read, Route53 propagation) is handled by polling-until with
  a generous-but-bounded timeout, which the existing tests already do.
- **Timeouts sized per resource class**, not a global value: secrets/DNS in
  tens of seconds; cert ISSUED minutes; cluster/DB the long windows. Encode
  the timeout next to the resource so it is reviewable.
- **Quarantine, never silence.** A test observed flaky gets an entry in
  `docs/open-issues.md` (AGENTS.md §6.18) with the verbatim symptom; two
  occurrences without an entry *is the problem*. Quarantine = move to a
  non-gating lane *with a tracking issue and an owner*, not `|| true`, not
  delete (AGENTS.md §6.24).
- **Precondition gating to kill false negatives.** The single biggest source
  of "flaky" live failures here is the rotated/stale-account class (§8.2 /
  §10.1). The bundle's first step (§3.1) hard-checks creds/cluster/state so a
  rotation fails *as a precondition*, with a distinct message, never as a
  confusing mid-test code failure.

---

## 8. Failure-class → catching-test matrix (the core deliverable)

The eight recent live failures, each mapped to the test tier that now catches
it, and *why the current estate missed it*.

| # | Failure (live, one-at-a-time) | Why it slipped through today | Now caught by | Tier | Authoring-time guard added |
|---|---|---|---|---|---|
| 1 | Missing cloud-IAM permissions → resources silently failed to create | chainsaw uses admin creds + fake cloud; unit checks policy *text* not *effect* | T4 instantiate under **restricted** controller role → create fails with `AccessDenied` *at authoring time*; T3 existence check finds the resource absent | T4 (+T3) | extend `test_iam_required_actions.sh`; coverage-manifest entry |
| 2 | Controller identity lacked its permission binding → could not act | nothing exercised the real binding; admin masked it | T4: controller acts under its real role and the call succeeds (fails if binding missing); positive IRSA live check | T4 | `irsa_trust_validator.py` static half already exists; add live half |
| 3 | Config default left at a value that blocked an entire trust mechanism | render/unit accepted the default; no live trust exercise | T4-negative asserts the safe value is **required** (bad default rejected); T3 verifies the trust path resolves live | T4-neg (+T3) | new unit assertion: required-non-default field |
| 4 | App identity name ≠ policy's expected principal → app authed to nothing, silently did nothing | name match never exercised end-to-end under real identity | T4: app uses its real identity to perform a real action and it **succeeds**; mismatch ⇒ test fails (no silent no-op) | T4 | extend `irsa_trust_validator.py` SA/principal sweep + live action |
| 5 | Missing cloud-network tags → load balancer never created | no test asserted the tags; e2e-verify didn't look | T3 tag-aware check on VPC/subnets; T4 ingress test: LB actually provisioned + curl 2xx/3xx | T3 (+T4) | new unit/Kyverno tag-presence check (cf. `SPEC-C3-terraform-resource-tag-check`) |
| 6 | (general) "told platform to create X; X never created / doesn't work" | only static "config says X"; no real-build assertion | T3 existence/health for *every* phase resource via coverage manifest | T3 | coverage-manifest unit test (§3.2 guard 3) |
| 7 | (general) shallow apply-and-verify passed while real thing broken | e2e-verify checks few things, existence-only | deepened, per-resource, tag- and identity-aware T3 | T3 | — |
| 8 | (precondition) auth service starts with DB unavailable | no health-gate test | T4-precondition: auth stays NotReady when DB withheld; Kyverno admit-gate | T4-pre | continuous Kyverno health-gate policy |

The throughline: **#1–#4 are caught by adding the restricted-identity
dimension (T4); #5–#7 by deepening after-the-fact live verification (T3) and
making coverage a unit-tested invariant; #8 by precondition/health-gate
testing.** None required mocking the cloud better — they required testing
against the *real* cloud under the *real* identity.

---

## 9. The restricted-identity mechanism (the crux, needs a specialist)

The plan's distinctive demand is: T4 tests run under the **restricted
controller identity**, not the admin CI key. How to obtain it:

- **In-cluster context (preferred):** the controllers already run under their
  restricted roles (IRSA — the SA carries a role-arn annotation). The most
  faithful T4 test runs *as that workload* (a job in the controller's
  namespace using the controller's SA), so the credentials path is identical
  to production. **[K8S-SPECIALIST]** to design: a minimal "verifier job"
  pattern that assumes/uses each controller SA, performs the positive and
  negative action, and reports back to the bundle. This is the highest-fidelity
  option and the one I recommend as primary.
- **CI context (fallback):** assume the controller role from the admin CI key
  (`sts assume-role` into the restricted role ARN) and run the
  positive/negative cloud calls. Lower fidelity (CI network path differs) but
  catches the permission/identity classes (#1–#4) cleanly. Useful when
  in-cluster job execution isn't wired.
- **Hermetic simulation (T2, cheapest, lowest fidelity):** wire the chainsaw
  provider with restricted creds even against the stub to catch *obvious*
  missing-action cases in `kind`. Treat as a fast pre-filter, not a
  replacement for T4. (See §11 open question on whether the stub honors this.)

**Why this matters:** admin creds are exactly what hid failures #1–#4. Any
plan that keeps testing under admin reproduces the blind spot. The restricted
identity is non-negotiable for T4; the only open question is the *mechanism*,
which is where a Kubernetes/IRSA specialist adds the most value.

---

## 10. Test observability and failure triage

A live suite is only as good as how fast you can tell *what* broke and
*whether it's the code or the environment*.

- **Strength-labeled output.** Every failure line states observation vs.
  hypothesis vs. conclusion (AGENTS.md §6.17). Live failures are
  ambiguous by nature; the report must not present a guess as a cause.
- **Auto-dump on every live failure.** Already true for claim waits
  (`wait-for-claim.sh` dumps conditions + composition events + cluster
  events). Standardize the same on all T3/T4 failures: the failing resource's
  `describe`, the controller's recent logs, and the relevant cloud `describe`
  output, inline in the run log. Reuse `scripts/crossplane-trace.sh`,
  `scripts/diag-component.sh`, the chainsaw shared `catch:` block.
- **Environment-vs-code disambiguation up front.** The precondition step (§3.1
  step 1) tags any failure that is actually a rotated account / unreachable
  cluster / missing tool as `ENVIRONMENT`, not `TEST FAIL`, with the §10.1
  failure-shape catalog. This stops the wasted debug loops the codebase has
  hit repeatedly (§8.2 history).
- **PR summary comment.** Extend the existing summary-comment mechanism to
  publish: per-tier pass/fail/skip counts, per-tier wall-clock vs. budget, the
  `LIVE_BUNDLE` switch state + reason, and the coverage-manifest delta (new
  resources without live tests block the merge, §7). Reuse
  `.github/scripts/post-comment.py` (note the `STEP_LABELS`/`OUTCOMES`
  keys-equal invariant already has a regression test — extend in lockstep).
- **Triage playbook.** A short doc: failure shape → first diagnostic →
  likely tier. Seeded from the bug-class registry, kept tight.

---

## 11. CI gating model

- **On push (cheap, every time):** T0 unit + kubeconform + Kyverno-lint +
  render-fixture diff + **the coverage-manifest unit test** (`test_live_coverage`)
  + the `LIVE_BUNDLE`-switch lint (reason-required). These are the fast
  always-on gates; they include the anti-regression guard so "no live test for
  a new resource" goes red *before* anyone runs a live workflow.
- **On bring-up (`apply-and-verify` / `verify`, dispatch):** the full live
  bundle (§3.1) runs by default, gating the phase's "verified" state.
- **Heavy-workflow discipline preserved.** Per AGENTS.md §6.7/§6.13, the live
  bundle (which boots/uses real cloud) stays `workflow_dispatch`-driven with a
  cheap push-time *verifier* that confirms a green live-bundle run exists for
  the PR's HEAD SHA. Run the pre-dispatch static audit before each dispatch.
- **Gate matrix testable.** Extend `compute-gates.sh` + its unit fixtures to
  cover the new `LIVE_BUNDLE` input so a gate-logic bug (e.g. running the
  bundle when disabled, or *skipping* it when enabled) is itself unit-tested
  (the `phase=test` philosophy in §8 of the guidelines).
- **Sync invariant.** Keep `tests/unit/run.sh` ↔ `unit-tests.yml` in sync
  (AGENTS.md §6.16) when the new unit tests land.

---

## 12. Phased rollout

Deliver in stacked PRs (AGENTS.md §3/§6.6), each independently green, lowest
risk first. **No new tests are drafted without the §6.4 adversarial-subagent
review** — that gate applies to this overhaul too.

- **Phase A — Make the gap visible (no behavior change, all static).**
  Add the coverage manifest + `test_live_coverage` unit test (initially
  permissive: warn-then-fail after a grace window) and the `LIVE_BUNDLE`
  switch lint. Outcome: every uncovered resource is now *listed*. Cheap, safe,
  immediately informative.
- **Phase B — Deepen T3 (after-the-fact), the highest ROI.** Replace the
  shallow `e2e-verify` with per-resource, tag-aware, identity-aware existence/
  health checks for the already-built cluster/DB/IAM/cert/DNS. Catches #5,#6,#7
  with no new resource creation cost.
- **Phase C — T4 instantiate-and-behave under restricted identity.** Wire the
  restricted-identity mechanism (§9), port the #11 PlatformSecret pattern to
  each XRD, add positive controller-action tests. Catches #1,#2,#4.
- **Phase D — Negative + precondition.** Bad-param rejection tests, the
  required-non-default assertions (#3), and the auth-DB health-gate (#8, both
  the Kyverno admit-gate and the live withhold-DB test).
- **Phase E — Bundle, switch, gating, observability.** Assemble
  `tests/live/run.sh`, wire it into `apply-and-verify` as on-by-default with
  the disable switch + skip-budget, the summary comment, the verifier
  workflow, and the gate-matrix unit tests. Flip `test_live_coverage` from
  permissive to enforcing.
- **Phase F — Hardening.** Orphan sweeper, idempotency double-run lane,
  parallel fan-out + quota-aware concurrency, triage playbook, flake
  quarantine lane.

Sequencing rationale: A makes the problem measurable; B is pure ROI with no
new cost; C/D close the identity and negative gaps (the eight failures); E
makes it always-on and un-regressible; F makes it cheap and durable.

---

## 13. Assumptions

1. The restricted controller role ARNs are discoverable at test time (from
   Terraform outputs / SA annotations) on the ephemeral account — consistent
   with the "never hardcode account-derived values" rule (§8.1).
2. CI / in-cluster context can either run a job as a controller SA or
   `sts assume-role` into the controller role. (If neither, §9's hermetic T2
   fallback is the floor, which is weaker — flag to user.)
3. The deepened T3 checks can read all needed cloud resources with the *admin*
   CI key (read-only `Describe*`), while T4 *actions* use the restricted role.
   T3 verification ≠ T4 instantiation; only the latter needs restricted creds.
4. Per-run isolation + cleanup primitives are sound to build on (verified —
   `RUN_ID`/`trap`/`add_cleanup` exist and are battle-tested).
5. The compute cluster and DB created by the bring-up persist for the session,
   so T4 app/identity tests can reuse them rather than create their own.

## 14. Open questions

1. **Restricted-identity mechanism (primary unknown).** In-cluster verifier
   job vs. CI `assume-role` — which is wired today, and is per-controller SA
   execution feasible? (§9) **[K8S-SPECIALIST]**
2. **Does the chainsaw AWS provider stub honor restricted creds** faithfully
   enough to make T2 worth building, or is T2 false comfort? (§2, §9)
   **[K8S-SPECIALIST]**
3. **Coverage-manifest source of truth:** can "resources this phase creates"
   be derived completely + automatically from Terraform plan JSON + Composition
   `resources[]`, or must it be hand-maintained (and thus itself drift)? (§3.2)
   **[K8S-SPECIALIST]**
4. **Health-gate primary route for #8:** Kyverno admit-gate vs. live
   withhold-DB test as the gating one (I propose both; which gates "verified"?)
   (§4.3) **[K8S-SPECIALIST]**
5. **Quota math** for safe T4 parallelism against the 9-instance EC2 ceiling
   given the live mgmt+spoke topology. (§5.2)
6. **Skip-budget threshold + grace window** for flipping `test_live_coverage`
   from permissive to enforcing without blocking unrelated work. (§3.2, §12)

## 15. Explicitly out of scope / deferred

- AWS API rate-limiting behavior as a tested contract (handled as transient-
  retry, not asserted).
- Replacing chainsaw/`kind` — it stays as the fast hermetic logic layer (T1);
  this plan *adds* live tiers, it does not remove the hermetic one.
- Load/performance/chaos testing of the platform.
- Multi-account / cross-region provisioning (single ephemeral account assumed).
- Building a higher-fidelity cloud mock — the whole point is to test against
  the real cloud where it matters; better mocks would re-create the blind spot.

---

*End of PLAN-C. PLAN-ONLY — nothing in this repository was created or modified
except this file.*
