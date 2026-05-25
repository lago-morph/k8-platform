# SPEC-B2 — `test_irsa_sa_pinned.sh`: every IRSA trust subject has a matching SA pin

## 1. Summary

Add a pure-local unit test that statically validates every IRSA role
declared in `terraform/management/irsa.tf` has a corresponding pinned
ServiceAccount name in one of the three places where the SA is
materialised in-cluster: a Crossplane `DeploymentRuntimeConfig` under
`crossplane/`, a Helm `serviceAccount.name` value under
`platform-services/`, or an explicit `metadata.name` on a `ServiceAccount`
manifest. If any `namespace_service_accounts` entry has no matching pin,
the test fails by naming the unpinned subject so the author can fix it
before the IRSA trust silently rejects the running SA at runtime.

## 2. Retro pain killed (PR #66 + #68 root cause chain)

- **PR #66 — root cause.** `terraform/management/irsa.tf` declared
  `namespace_service_accounts = ["crossplane-system:upbound-provider-family-aws"]`,
  but the Crossplane provider controller created the SA from a
  revision-hash-derived name (`provider-family-aws-24aaab54a3a0`).
  The IRSA trust policy's `StringEquals` on `system:serviceaccount:crossplane-system:upbound-provider-family-aws`
  rejected every `AssumeRoleWithWebIdentity` from the actually-running
  SA. Symptom at claim level: every ASM `Secret` MR stalled
  `Ready=False`, no `atProvider.arn`, no parseable error — the OIDC
  rejection happened inside the provider pod and was visible only in
  the controller's own logs. Lost hours on diagnose run 26353150253.
- **PR #66 fix.** Add a `DeploymentRuntimeConfig` with
  `spec.serviceAccountTemplate.metadata.name: upbound-provider-family-aws`
  to pin the SA name to the IRSA trust subject. See
  `terraform/management/helm.tf` lines ~142–175 (the inline manifest
  in `local.crossplane_aws_provider_manifest`).
- **PR #68 follow-up.** Even after the pin landed, the running pod
  stayed mounted on the old hash-suffixed SA because Crossplane's
  Provider controller only re-renders the Deployment when the
  `Provider` object changes — a `DeploymentRuntimeConfig` edit alone
  doesn't trigger a roll. The fix is a `kubectl delete deploy -l
  pkg.crossplane.io/provider=...` after the apply. That secondary
  failure is out of scope for this spec — Kyverno SPEC-B4 catches
  the runtime mismatch; this spec catches the *authoring-time*
  omission that started the chain.
- **The bug class.** Any IRSA role whose trust subject is a literal
  `namespace:serviceaccount` string but whose consumer (Helm chart,
  Crossplane provider, raw manifest) defaults to a derived /
  hash-suffixed / random SA name. The static contract — "if the
  trust says SA name = X, something in-cluster has to pin SA name = X"
  — is mechanically checkable from the repo content alone.

## 3. Out of scope

- **Does NOT validate the trust policy JSON schema itself.** Whether the
  `Condition` block is `StringEquals` vs `StringLike`, whether `aud` is
  set correctly, whether the OIDC provider ARN resolves — none of that
  is checked here. `terraform validate` and the
  `iam-role-for-service-accounts-eks` module own that contract.
- **Does NOT verify the SA exists at runtime.** That is SPEC-B4's job
  (Kyverno audit policy that compares the live SA name against the
  IRSA role's trust subject). This test fires at PR-author time; the
  Kyverno policy fires continuously against the live cluster.
- **Does NOT verify the IRSA role is actually consumed** (helm_release
  references `module.irsa_X.iam_role_arn`). `test_irsa_helm_linkage.sh`
  already owns that contract — this test is the orthogonal "the SA
  the role *trusts* will exist with the right name" check.
- **Does NOT inspect Helm chart upstream defaults.** If the chart's
  default SA name happens to match the IRSA trust subject and no
  explicit `serviceAccount.name` is set in our values, that's a
  configuration we choose not to trust — pin it explicitly or
  allowlist it (see §4).

## 4. Files to create

- `tests/unit/test_irsa_sa_pinned.sh` — the test script. Conventions
  match `test_irsa_helm_linkage.sh`: sources `lib/test-helpers.sh`,
  uses `pass` / `fail` / `summary`, no AWS calls, no cluster calls.
- `tests/unit/fixtures/irsa_sa_pinned/` — fixture trees used by the
  meta-tests (see §6). Contains both a passing fixture and a
  PR-#66-replica failing fixture.
- `tests/unit/test_irsa_sa_pinned.allowlist` — optional newline-
  delimited file of `namespace:serviceaccount` strings that are
  intentionally not pinned in-repo (e.g. an IRSA role created for a
  workload that lives in a different repo, or a role still being
  bootstrapped). Each entry MUST carry a `# reason: …` comment on the
  same line. Empty / absent file = empty allowlist.

## 5. Implementation notes

### 5.1 Terraform parsing approach

Three options ranked by complexity:

1. **Regex** (chosen). The `namespace_service_accounts` declarations
   in `irsa.tf` are stable in form:
   `namespace_service_accounts = ["ns:sa", "ns:sa", ...]`. A
   `grep -oE` on `"[a-z0-9-]+:[a-z0-9-]+"` inside the
   `namespace_service_accounts = \[ ... \]` blocks extracts the full
   set with no external tool dependency. CI dependency: bash + grep
   + sed (all present on the `ubuntu-latest` runner and in every
   developer's environment). This matches the style of the existing
   `test_irsa_helm_linkage.sh`.
2. **`hcl2json`** — clean but adds a binary the rest of the unit
   suite does not depend on. Reject unless the regex approach proves
   brittle.
3. **`terraform show -json`** — requires `terraform init` against a
   real backend. Defeats the "pure-local, no AWS" property of the
   unit suite (per AGENTS.md §6.3). Reject.

If a future IRSA role uses a `for_each` over a variable map or
otherwise interpolates the SA list, the regex will miss it. Mitigation:
the test fails closed — if an `irsa_*` module exists with zero
extracted SA strings, that is itself a `fail` so the author either
pins inline or upgrades the parser. Do NOT silently skip such modules.

### 5.2 Module handling

The repo currently inlines every IRSA role in `terraform/management/irsa.tf`
via the upstream `terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks`
module. The test parses our wrapper invocations, not the upstream
module's internals. If future work moves IRSA into a local module
under `terraform/modules/`, extend the scan path list — keep the
allowed paths in a small `IRSA_TF_PATHS` array at the top of the
script. Out-of-tree IRSA (e.g. roles created by Crossplane Compositions
at runtime) is out of scope.

### 5.3 The three pin sources

For each extracted `namespace:serviceaccount`, search:

1. **DeploymentRuntimeConfig under `crossplane/` and inline in
   `terraform/management/helm.tf`.** Match
   `kind: DeploymentRuntimeConfig` documents and look for
   `spec.serviceAccountTemplate.metadata.name == <sa>`. The
   namespace on a `DeploymentRuntimeConfig` is implicit (Crossplane
   places the SA in the provider's runtime namespace, which is
   `crossplane-system` for the current provider set); for now,
   only match the SA name and rely on the author to keep the IRSA
   trust namespace correct. If the bug class ever drifts on the
   namespace side, add a namespace cross-check.
2. **Helm `serviceAccount.name` values.** Two shapes appear in this
   repo:
   - Values files under `platform-services/<svc>/values*.yaml` —
     match `.serviceAccount.name == <sa>` (or
     `.server.serviceAccount.name`, `.controller.serviceAccount.name`
     for charts with subcharts; the test walks a small list of
     known prefixes).
   - `set { name = "serviceAccount.name", value = "<sa>" }` blocks
     inside `terraform/management/helm.tf`. The existing
     `helm_release` blocks set the IRSA *annotation* but rely on
     the upstream chart's default SA name; if a future chart needs
     an explicit name pin, this is where it lands.
3. **`metadata.name` on `kind: ServiceAccount` manifests anywhere
   under `crossplane/` or `platform-services/`.** Use yq
   `select(.kind == "ServiceAccount") | .metadata.namespace + ":" + .metadata.name`
   and check the resulting set contains `<sa>` (namespace-qualified).

A subject is considered pinned if **any** of (1), (2), (3) matches.

### 5.4 Cross-namespace handling

Sources (1) and (2) match on the SA name only; source (3) matches
on `namespace:name`. This asymmetry is deliberate: Crossplane and
most Helm charts derive the namespace from the release / runtime
config, not from a values key. The risk is a name collision across
namespaces (two IRSA roles both trusting `*:external-dns`); the
inverse check in §6.4 below catches it.

## 6. Tests required

Per AGENTS.md §6.1 and §6.2:

### 6.1 Meta-tests with fixture trees

Under `tests/unit/fixtures/irsa_sa_pinned/`:

- `passing/` — minimal repo skeleton with one IRSA role
  (`crossplane-system:upbound-provider-family-aws`) and a matching
  `DeploymentRuntimeConfig` pin. The test, when pointed at this
  fixture, must `exit 0`.
- `failing-pr66/` — exact PR #66 reproduction: IRSA role declared,
  no `DeploymentRuntimeConfig`, no Helm values pin, no SA manifest.
  Test must `exit 1` and the failure line must contain the literal
  string `crossplane-system:upbound-provider-family-aws`.
- `failing-typo/` — IRSA trust says `upbound-provider-family-aws`
  but the `DeploymentRuntimeConfig` pin says
  `upbound-provider-aws-family` (transposed words). Test must
  `exit 1` — confirms the matcher is exact, not fuzzy.
- `passing-helm-values/` — IRSA role for
  `external-dns:external-dns`, no DeploymentRuntimeConfig, pin
  lives in a Helm values file at
  `platform-services/external-dns/values.yaml`
  (`serviceAccount.name: external-dns`). Confirms source (2) works.
- `passing-sa-manifest/` — IRSA role for `app:my-app`, pin lives
  in a raw `ServiceAccount` manifest with explicit
  `metadata.namespace: app` / `metadata.name: my-app`. Confirms
  source (3) works.
- `passing-allowlist/` — IRSA role with no in-repo pin, but the
  subject is in `tests/unit/test_irsa_sa_pinned.allowlist` with a
  `# reason:` comment. Test must `exit 0`.

The harness drives each fixture by exporting `IRSA_SA_PIN_ROOT=<fixture>`
before invoking the script; the script honours that env var when
set and defaults to the repo root otherwise. The meta-tests live
inline in `test_irsa_sa_pinned.sh` itself behind a
`--self-test` flag, mirroring the pattern in
`test_compute_gates.sh` if one exists, else add a parallel
`test_irsa_sa_pinned_meta.sh` driver. (Pick one and state the
choice in the PR.)

### 6.2 TDD reproduction of PR #66

The `failing-pr66/` fixture above IS the TDD bug reproduction. To
satisfy §6.2 step 2 ("run the test against the unfixed code, confirm
red"), the spec authoring sequence is:

1. Land `failing-pr66/` fixture and the `--self-test` driver first.
   The driver asserts the main script exits non-zero on that fixture.
   At this point the main script does not yet exist — the driver
   itself fails red.
2. Land the main script. The `failing-pr66/` driver now passes
   (script correctly identifies the unpinned subject), and pointing
   the script at the real repo also passes because PR #66's fix
   already landed.
3. Commit fixture + script together (§6.2 step 5).

## 7. Documentation updates

- `tests/unit/README.md` (if absent, create with a single table of
  test → contract): add row for `test_irsa_sa_pinned.sh` →
  "Every IRSA trust subject has a matching SA pin in-repo".
- `ai/TESTING-PLAN.md` bug-to-test traceability matrix: add a row
  citing PR #66 → unit / `test_irsa_sa_pinned.sh`.
- Brief comment block at the top of `irsa.tf` cross-referencing the
  test so a future author adding an IRSA role sees the obligation
  without having to read this spec. One sentence; no duplication.

## 8. Workflow / auto-invocation wiring

- Add `run_suite tests/unit/test_irsa_sa_pinned.sh` to
  `tests/unit/run.sh`. Position it adjacent to
  `test_irsa_helm_linkage.sh` so the IRSA-related checks group
  visually in the run log.
- `.github/workflows/unit-tests.yml` runs `tests/unit/run.sh` on
  every push and PR (per AGENTS.md §6.7 — unit-tests is a light
  workflow that fires on push). No workflow YAML change needed
  beyond the `run.sh` registration.
- No new dependencies. `yq` and `grep` are already on the
  unit-tests runner image (used by other tests).

## 9. Discoverability for future agents

- The test fires on every push via `unit-tests.yml`; a failing PR
  check writes one line per unpinned subject:
  `FAIL: <ns>:<sa> declared in irsa.tf has no matching SA pin in
  crossplane/, platform-services/, or DeploymentRuntimeConfig`.
  That message names the exact file class to fix.
- The cross-reference comment in `irsa.tf` (§7) gives any author
  adding a new IRSA module a pointer before they push.
- The fixture directory `tests/unit/fixtures/irsa_sa_pinned/` is
  self-documenting: each subdir name encodes the intent
  (`failing-pr66`, `passing-helm-values`, etc.).
- The retro for PR #66 / #68 should cite this test by path so a
  future bug-class search lands on the spec.

## 10. Verification checklist

- [ ] `tests/unit/test_irsa_sa_pinned.sh` passes against current
      `main` (PR #66 fix is already merged, all current IRSA roles
      have matching pins).
- [ ] `--self-test` exits 0 (all six fixture cases behave as
      declared in §6.1).
- [ ] Deleting the `DeploymentRuntimeConfig` pin in
      `terraform/management/helm.tf` and re-running the test fails
      with a message containing
      `crossplane-system:upbound-provider-family-aws`.
- [ ] Adding a new fake IRSA module
      (`namespace_service_accounts = ["foo:bar"]`) and re-running
      the test fails with a message containing `foo:bar`.
- [ ] Adding `foo:bar` to the allowlist with a
      `# reason: scratch test` comment makes the test pass again.
- [ ] Removing the allowlist comment (just the bare subject) makes
      the test fail with "allowlist entry needs a reason".
- [ ] Test completes in under 2 seconds on a cold checkout.
- [ ] Test produces zero output on `pass` cases beyond the standard
      `PASS:` lines from `test-helpers.sh`.

## 11. Rollout notes

Before merging the test, audit every current IRSA role in
`terraform/management/irsa.tf`:

| Role | Trust subject(s) | Pin location |
|---|---|---|
| `irsa_argocd` | `argocd:argocd-server`, `argocd:argocd-application-controller` | Upstream chart's default SA names — must verify and either confirm the chart pins these names by default (acceptable: source 2 via `set` block) or add to allowlist with reason "ArgoCD chart default SA names are stable". |
| `irsa_crossplane` | `crossplane-system:upbound-provider-family-aws` | `DeploymentRuntimeConfig` inline in `terraform/management/helm.tf` (source 1). |
| `irsa_eso` | `external-secrets:external-secrets` | Upstream ESO chart default — verify or pin. |
| `irsa_external_dns` | `external-dns:external-dns` | `platform-services/external-dns/values.yaml` (source 2) — verify present. |

The test must be green at merge or it is hostile — a hostile lint
trains the team to ignore failures. If an audit row resolves to
"chart default", the choice is (a) add an explicit `set { name =
"serviceAccount.name", value = "<sa>" }` in `helm.tf` so the pin is
load-bearing and not a coincidence, or (b) add the subject to the
allowlist with a reason that names the upstream chart and version.
Prefer (a); (b) is technical debt.

If audit reveals any current IRSA role has no pin and no defensible
allowlist reason, fix it in the same PR — that's a latent PR #66
recurrence and the test caught it pre-merge, exactly as designed.

## 12. Estimated effort

**S** (small). ~150 lines of bash for the main script, ~6 fixture
trees of 2–4 files each, one `run.sh` registration, one
documentation row. Comparable in size and shape to
`test_irsa_helm_linkage.sh` (90 lines) plus the fixture overhead.
Half-day including the audit in §11 and the adversarial-subagent
review required by AGENTS.md §6.4.
