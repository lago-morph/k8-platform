# Open Issues — durable register of undiagnosed problems

Anything observed that we did not fully diagnose goes here. Per AGENTS.md
§6.18 ("Never ignore an undiagnosed failure"), an open issue is a
hard requirement — we record what happened, what we ruled out, and the
next concrete diagnostic step. The list shrinks as items get closed
(with evidence) and grows as new ones surface.

Each entry uses the format below. Identifier `OI-YYYY-MM-DD-N` where N
is the sequence number for that date.

---

## OI-2026-05-28-1 — `composition-drift` first-scenario timeout on chainsaw

**Status:** **partially resolved** — Issue B (cleanup path bug) **RESOLVED**
(fix landed in PR #129; verified in code 2026-05-29); Issue A (first-scenario
XR-Ready timeout) still **open**, hypothesis-level.
**Surfaced:** 2026-05-28, PR #125 chainsaw dispatch (run id `26552671925`,
HEAD SHA `b31cc87`).
**Re-dispatch:** 2026-05-28, run `26553581065` against the same SHA produced
a DIFFERENT failure pattern, which is what surfaced Issue B.

### Issue B — `composition-drift` cleanup silently fails to restore the mutated Composition

**Status:** **RESOLVED** (verified 2026-05-29, auto-004). The fix already
landed via PR #129 (commits `0e31154` "restore Composition from /tmp
snapshot, not cwd-relative on-disk path" + `e834a8a` "strip read-only
fields from pristine snapshot"). `tests/chainsaw/_meta/composition-drift/chainsaw-test.yaml`
now snapshots the pristine Composition to `/tmp/composition-pristine.yaml`
in the mutate step and restores from that path (CWD-independent) guarded by
`if [ -f ... ]` with **no `|| true`** — so a future restore failure exits
non-zero immediately instead of cascading. The register entry below was
stale; closing it. Real-AWS chainsaw re-confirmation is the last step.
**Root cause (historical):** The composition-drift scenario's
"restore the Composition (cleanup)" script runs:
```sh
kubectl apply -f crossplane/compositions/platform-secret.yaml || true
```
Chainsaw runs scripts with its own CWD (under `tests/chainsaw/`), not the
repo root, so the relative path doesn't resolve. The `|| true` swallows the
error. Verbatim from run `26553581065` log:
```
error: the path "crossplane/compositions/platform-secret.yaml" does not exist
```
**Consequence:** When `composition-drift` reaches the mutation step (which
it did in run `26553581065` but not in run `26552671925`, see Issue A), the
on-cluster Composition stays at `recoveryWindowInDays: 7`. All subsequent
scenarios (`claim-creates-secret`, `claim-rotation`, `claim-deletion-cleanup`)
reconcile against the mutated Composition. Their goldens assert
`recoveryWindowInDays: 0` and fail with diff at the chainsaw assert timeout
(~249-253s). This is the cascading triple-failure observed in run `26553581065`.
**Fix:** (1) compute the composition path absolutely (e.g. `$(git rev-parse
--show-toplevel)` or chainsaw's `$CHAINSAW_ROOT` if it sets one); (2) drop
the `|| true` so the next time the apply fails, the cleanup step exits
non-zero and the failure is visible immediately rather than cascading.
**Next action:** open a stacked PR (Task 6) with the fix. Hold pending
user confirmation per §6.5.

### Issue A — `composition-drift`'s XR takes >245s to become Ready (first run only)

**Status:** still hypothesis-level. The Issue B diagnosis does NOT explain
Issue A — in run `26552671925` the XR was Unready at `wait for XR Ready`'s
245s timeout BEFORE composition-drift could reach the mutation step. The
asm-secret MR had `status.Ready=False, reason=Creating`. In run
`26553581065` the same XR became Ready in time. Both runs were on the same
SHA, same composition, fresh kind cluster per run.
**Hypotheses (UNCONFIRMED — no positive evidence):**
- AWS-provider cold start that varies between dispatches.
- IAM permission propagation lag on the freshly-issued GHA access key
  (a few-minutes window where the key works for some calls and not
  others).
- Transient AWS API throttling or upstream provider hiccup.
**Ruled out:**
- Stale credentials (`§8.2`): later scenarios in the FIRST run authenticated
  and provisioned ASM secrets successfully via the AWS CLI; later scenarios
  in the SECOND run also authenticated (their failure was the
  recoveryWindowInDays diff, not an AWS API error).
- Regression from Task 2: `git diff main chore/audit-wiring-fixes-2026-05-02
  -- crossplane/ tests/chainsaw/` is empty.
**Next diagnostic step:** the catch block now uses `-A` (post the
chore/audit-wiring-fixes-2026-05-05 fix) so the asm-secret MR's
`status.conditions` and `status.atProvider` will be captured on the next
occurrence. Re-dispatch only after Issue B is fixed (so subsequent
scenarios don't cascade-fail and obscure Issue A).
**Owner / next action:** Issue A defers; Issue B is the immediate fix.

**2026-05-29 update (auto-004, NEW POSITIVE EVIDENCE — run `26621695077`):**
Recurred on a fresh account, this time on the **`claim-rotation`** scenario
(not composition-drift). 5/6 real-AWS scenarios passed
(`claim-creates-secret` in 10.7s, `claim-deletion-cleanup`, `composition-drift`,
`xrd-establishes`, `_smoke`); only `claim-rotation` failed at the
`wait for claim Ready` 240s timeout. The catch block captured the actual
provider error (the earlier occurrences only showed `Ready=False,
reason=Creating`):
```
CannotCreateExternalResource ... ResourceExistsException: The operation
failed because the secret k8-platform/<xr-uid> already exists.
```
This **sharpens the hypothesis** from "XR is just slow" to a **CreateSecret /
Observe double-create race**: the AWS provider issues `CreateSecret`, then a
second reconcile re-issues `CreateSecret` before the first is observable
(AWS Secrets Manager read-after-write lag) → `ResourceExistsException`, and
the MR can get stuck re-attempting create rather than adopting the existing
secret, so the XR never reaches Ready within 240s. Consistent with
"flaky / load-dependent" (the same Composition's `claim-creates-secret`
passed in 10.7s in the same run). Still **hypothesis**, not confirmed —
candidate fixes to evaluate if it recurs deterministically:
(a) run chainsaw scenarios serially (reduce parallel provider load),
(b) raise `claim-rotation`'s assert timeout above 240s,
(c) investigate the provider's external-name persistence after first
    CreateSecret (the real fix if the MR never self-heals).
Also noted: `tests/chainsaw/run.sh`'s cleanup trap deletes by
`ASM_PREFIX="k8-platform-chainsaw"`, but the Composition names secrets
`k8-platform/<uid>` — so scenario secrets are NOT swept by the prefix
cleanup (they linger until manually removed). Separate minor issue; logged
here for the next session. **Next action:** re-kicked chainsaw once to test
the flake hypothesis (auto-004).

---

## OI-2026-06-05-1 — `yq/awk | grep -q` under `set -o pipefail` flakes unit tests

**Status:** **RESOLVED** (diagnosed + fixed, auto-005 long-run).
**Surfaced:** 2026-06-05, full local `tests/unit/run.sh` run during the
auto-005 audit — `test_platform_cluster_composition.sh`'s
`composition_policy_AmazonEKSWorkerNodePolicy` assertion failed
intermittently (`missing policyArn arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy`).

**Root cause (CONFIRMED by repro + fix, not hypothesis):** the assertion ran
`yq -r "...resources[]...policyArn..." "$COMP" | grep -qF "$arn"` under
`set -uo pipefail`. `grep -q` exits on its first match and closes the pipe;
the still-writing `yq` then takes `SIGPIPE` (exit 141), and `pipefail`
propagates that 141 as the pipeline's status, so the `if` intermittently
takes the `else` branch and emits a false FAIL. Measured **~10% (2-3/20-30)**
before the fix.

**Fix:** capture the producer's output to a variable, then `grep -q … <<<"$var"`
(here-string — no upstream process to receive SIGPIPE). Applied to every
instance of the class found in `tests/unit/`:
- `test_platform_cluster_composition.sh` (the observed one),
- `test_argocd_bootstrap.sh` (2 sites, `awk … | grep -q`),
- `test_diag_component.sh` (2 sites, `awk … | grep -q`).
`yq --version | grep -q mikefarah` sites were left as-is (single-line output,
producer already exited — no SIGPIPE window).

**Verification:** the previously-flaky test ran **0/30** failures after the
fix (was ~3/30). All three touched tests pass standalone.

**Prevention note (candidate AGENTS rule / lint):** "Never `producer | grep
-q` under `pipefail` when the producer emits more than one line — capture and
`grep -q <<<"$var"`." Surfaced for the retro.

---

## OI-2026-05-28-1 Issue B-adjacent — ASM cleanup-trap gap: **RESOLVED**

**Status:** **RESOLVED** (auto-005 long-run). The "Also noted" item in
OI-2026-05-28-1 below — `tests/chainsaw/run.sh` swept ASM secrets by
`${ASM_RUN_PREFIX}/` (`k8-platform-chainsaw-<id>/`) while the Composition
names them `k8-platform/<uid>`, so they never matched and leaked — is fixed.
The cleanup now enumerates the real names from the Secret MRs in the live
kind cluster (`tests/chainsaw/_lib/asm-cleanup.sh`) and deletes exactly
those, before `kind delete`. Behavioral unit test:
`tests/unit/test_chainsaw_asm_cleanup.sh`. (Issue A — the
`ResourceExistsException` rotation race itself — remains open; see decision
brief `decisions/auto-006-asm-external-name-fix.md`.)

---

## OI-2026-06-05-2 — `charts.crossplane.io` 403s the GitHub Actions runner

**Status:** **mitigated** (chart vendored); root cause still **hypothesis**.
**Surfaced:** 2026-06-05 auto-005 long-run — `phase=management
apply-and-verify` failed twice in a row (runs 27021786260, 27022894643), both
ONLY on `helm_release.crossplane`:
```
Error: could not download chart: looks like "https://charts.crossplane.io/stable"
is not a valid chart repository or cannot be reached: failed to fetch
https://charts.crossplane.io/stable/index.yaml : 403 Forbidden
```
Everything else applied (EKS cluster, ArgoCD, ESO, Kyverno, ingress-nginx,
external-dns, the bootstrap + argocd-admin-password provisioners).

**Evidence:**
- The same URL returns **HTTP 200** from the sandbox (and `master/index.yaml`
  too), and the index still lists `crossplane-2.3.0.tgz` — so the repo is up
  and the chart was NOT migrated/yanked.
- Two deterministic failures 4 min apart rule out a one-off transient.
- The prior successful management build (2026-05-29, run 26621556820) used the
  same URL — so this is a recent change in how the CDN treats the runner.

**Hypothesis (labelled, §6.17):** the CDN fronting `charts.crossplane.io`
(S3/CloudFront-class) is returning 403 to the GitHub-hosted runner egress
range specifically (IP/geo/UA based or rate-limited), while other networks get
200. NOT confirmed — I cannot curl from the runner directly. No public incident
found via web search.

**Mitigation applied:** vendored the digest-verified chart into
`terraform/management/vendor/crossplane-2.3.0.tgz` (sha256
`2ceff920…cd7f`, matches the upstream index digest) and switched
`helm.tf`'s `helm_release.crossplane` to install from that local path. The
apply is now hermetic and independent of the CDN. `terraform validate` passes.

**Next / revert:** if the CDN restriction lifts (re-check from a runner via a
probe step), restore the `repository`/`version` form and delete the tarball.
Consider asking Crossplane to publish the chart via OCI (xpkg/ghcr) — neither
`oci://xpkg.crossplane.io/crossplane/crossplane` nor `oci://ghcr.io/crossplane/
crossplane` exists today, so OCI was not an option.

---

## OI-2026-06-05-3 — provider-family-aws install races the package manager on fresh Crossplane

**Status:** **RESOLVED** (fix landed; pending live re-confirmation on the re-run).
**Surfaced:** 2026-06-05 auto-005 — management `apply-and-verify` run
27023573285 (branch ref, vendored-chart fix applied) failed at
`terraform_data.crossplane_aws_provider` (helm.tf:232):
```
deploymentruntimeconfig.../aws-provider-config created
provider.../provider-family-aws created
No resources found ... ERROR: expected SA upbound-provider-family-aws, got: MISSING
```
**Root cause (CONFIRMED by reading the log):** the provisioner applied the
`DeploymentRuntimeConfig` + `Provider`, then immediately `delete deploy -l … --wait=false`
and `kubectl rollout status -l …`. On a **fresh** Crossplane install the package
manager has not yet pulled the package image and created the provider's
Deployment + ServiceAccount, so `rollout status -l <sel>` returns "No resources
found" (non-zero) **immediately** (it does not wait for a matching resource to
appear), and the SA post-check then fails with `MISSING`. The prior successful
build (2026-05-29) won the race by luck (faster pull).

**Fix (helm.tf):** (1) `kubectl wait --for=condition=Healthy
provider.pkg.crossplane.io/provider-family-aws --timeout=300s` BEFORE the delete
(guarantees the Deployment+SA exist); (2) after the delete, poll for the
Deployment to reappear (the package manager doesn't recreate it instantly)
before `rollout status`. POSIX /bin/sh. `terraform validate` passes. Handles
both fresh-install and DRC-change-upgrade cases.

---

## OI-2026-06-05-4 — v2.5.0 family-provider Deployment lacks the `pkg.crossplane.io/provider` label the provisioner selected on

**Status:** **mitigated** (provisioner no longer depends on the label).
**Surfaced:** 2026-06-05 auto-005, run 27023830973 — with the OI-2026-06-05-3
Healthy-wait in place, the log showed:
```
provider.pkg.crossplane.io/provider-family-aws condition met   (Healthy)
No resources found                                             (delete -l … matched nothing)
ERROR: provider Deployment never reappeared after delete
```
**Root cause:** `terraform_data.crossplane_aws_provider`'s provisioner did
`kubectl -n crossplane-system delete deploy -l pkg.crossplane.io/provider=provider-family-aws`
and `kubectl rollout status -l <same>`. The Provider is Healthy (so its
Deployment+SA exist) but **nothing in crossplane-system carries that label** on
the Upbound v2.5.0 family provider — `kubectl rollout status -l <sel>` /
`delete -l <sel>` therefore match nothing. This delete+rollout-by-label was a
re-roll mechanism for a DRC SA-name *change*; it is unnecessary on a fresh
install (the DRC is applied WITH the Provider, so the Deployment is created with
the pinned SA from the start). It is also where OI-2026-06-05-3's first fix still
failed.
**Fix:** drop the by-label delete/rollout. Keep `kubectl wait
--for=condition=Healthy provider/provider-family-aws`, add a label-agnostic poll
for the `upbound-provider-family-aws` SA to materialise, and a diagnostics dump
(`get deploy,sa --show-labels`, pod serviceAccounts, providers/providerrevisions)
so the real labels are visible in the log. The existing hard gate (SA object
name == `upbound-provider-family-aws`) is retained. The diagnostics will reveal
the actual provider-Deployment label for a future, precise re-roll if a DRC
SA-name change is ever needed. terraform validate passes.

---

## OI-2026-06-06-1 — `crossplane render` defaulted to a floating `:stable` orchestrator image → `unexpected argument internal`

**Status:** **RESOLVED** (root-caused + fixed + verified green with the real
tools this session).
**Surfaced:** every push — `unit-tests.yml` `test_composition_render_fixtures.sh`
failed its 2 `*_render_matches_golden` subtests on `main` (e.g. run 27050411763,
HEAD `f39fee40`):
```
crossplane: error: cannot render composite resource: cannot run crossplane
internal render in Docker: container exited with status 1: crossplane: error:
unexpected argument internal
```

**Root cause (CONFIRMED, not hypothesis — reproduced locally with `--verbose`):**
`crossplane render` does the actual composition rendering by running
`crossplane internal render` inside a **Crossplane Docker image**, separate from
the function container. That orchestrator image defaults to the FLOATING tag
`xpkg.crossplane.io/crossplane/crossplane:stable`, which currently resolves to
**v1.20.9** (the v1.x stable line). v1.20.9 has no `internal render` subcommand,
so it rejects the args with `unexpected argument internal`. The function image
(`function-patch-and-transform:v0.10.6`) was never the problem; the breakage was
purely the un-pinned orchestrator image drifting. It was NOT a CLI-version drift
(reproduced identically with the CLI pinned to v2.3.0) and NOT any manifest bug.

**Fix:**
1. `scripts/composition-render.sh` now passes `--crossplane-version v${CROSSPLANE_CHART_VERSION}`
   (→ `v2.3.0`) to `crossplane render`, pinning the orchestrator image to the
   SAME Crossplane the management cluster runs (`read_crossplane_version()` reads
   the existing `versions.env` pin — single source of truth, cannot drift from
   the chart).
2. `.github/workflows/unit-tests.yml` now installs the crossplane CLI pinned to
   `v${CROSSPLANE_CHART_VERSION}` from the releases `crank` binary, instead of
   `install.sh` from `main` (the flag-parsing CLI must also be pinned).

**Verification:** with mikefarah `yq` v4.44.3 + crossplane CLI v2.3.0 + a running
dockerd, `bash tests/unit/test_composition_render_fixtures.sh` → **12/12 pass**
(both goldens match, both determinism sub-tests pass). The existing render test
is the regression catcher: if the pin is removed the floating image returns and
the test reds again.

**Note:** the sandbox ships the Python `yq` (kislyuk) by default, which silently
breaks `normalize_stream`'s mikefarah syntax and produces spurious golden
mismatches locally — install mikefarah/yq v4.44.3 before running the render test
in the sandbox (CI already does).

<!-- New entries go above this line, newest first. -->
