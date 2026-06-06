# auto-009 — Stacked-PR landing plan (phases 3–6 → `main`)

Investigation date: 2026-06-06. Read-only investigation; no PR was modified, merged, or pushed.

Goal: land the auto-007 stacked chain onto `main` **in order**:
`#144` (trunk) → `#145` (phase-3 spoke) → `#146` / `#147` / `#148` (phases 6/4/5).

Stack head SHAs / bases at investigation time:

| PR | branch | base.ref | base.sha | head.sha | mergeable_state | changed_files | commits |
|----|--------|----------|----------|----------|-----------------|---------------|---------|
| #144 | `claude/long-run-phases-3-6-7icMB` | `main` | `c3a6cb3` (current main) | `a3481a2` | `unknown` (GitHub still computing; was just re-based onto main) | 13 | 6 |
| #145 | `feat/phase3-spoke-foundation` | `claude/long-run-phases-3-6-7icMB` (#144) | `b1247e8` | `f882c41` | `unknown` | 23 | 5 |
| #146 | `feat/phase6-workload1-cluster` | `feat/phase3-spoke-foundation` (#145) | `f882c41` | `21f4278` | `clean` | 9 | 1 |
| #147 | `feat/phase4-observability-scaffolding` | `feat/phase3-spoke-foundation` (#145) | `f882c41` | `5edcf08` | `clean` | 9 | 1 |
| #148 | `feat/phase5-keycloak-auth` | `feat/phase3-spoke-foundation` (#145) | `f882c41` | `7febe91` | `clean` | 10 | 1 |

Note: #146/#147/#148 report `mergeable_state: clean` only **relative to their current base `#145`'s branch**, not to `main`. Their cleanliness against `main` is not yet computable until #145 lands.

---

## Findings

### 1. The `chainsaw-verify` gate (`.github/workflows/chainsaw-verify.yml`, on `main`)

It is a **lightweight, < 5 s verifier** (no kind/Crossplane/docker). It does NOT run chainsaw; it queries the GitHub Actions API for a **`chainsaw.yml` run whose `head_sha` == this commit AND `conclusion == "success"`**. Green if one exists, red otherwise. It implements the AGENTS §6.7 "manual-verify-then-PR" pattern: the agent is expected to dispatch `chainsaw.yml` on the exact HEAD and confirm green *before* opening/settling the PR.

Trigger block (quoted verbatim):

```yaml
on:
  push:
    branches-ignore:
      - main
    paths:
      # Mirror the chainsaw workflow's path filter — the verifier only
      # runs when the chainsaw harness would have run, so PRs that don't
      # touch crossplane/chainsaw paths get no verifier check at all.
      - ".github/workflows/chainsaw.yml"
      - ".github/workflows/chainsaw-verify.yml"
      - "crossplane/**"
      - "tests/chainsaw/**"
      - "tests/unit/test_chainsaw_kind_config.sh"
  workflow_dispatch:
```

So it fires on **push to any non-`main` branch** but ONLY when the push touches one of those paths. It is **SHA-exact**: it keys on the pushed HEAD `head_sha`.

**Why is it red on #144?** #144's check runs (HEAD `a3481a2`):
- `Verify chainsaw ran green on this commit` → **failure**
- `Unit tests` → success; `base — fmt + validate` → success; `management — fmt + validate` → success.

It is red because **no green `chainsaw.yml` run exists for SHA `a3481a2`** (the freshly-rebased-onto-main HEAD). The verifier fired on #144 because the trunk's diff carries crossplane/chainsaw-path files (the trunk includes `decisions/auto-008…`, retro material, and — per its file list — sits on a branch whose push matched the path filter / a prior chainsaw-touching commit). It is a **stale-SHA** red, not a functional failure: nothing chainsaw-relevant is broken, there is simply no chainsaw run pinned to the new merge-base HEAD. PR #142's own body documents this exact behavior: *"The `chainsaw-verify` check is SHA-exact and will be red unless a green `chainsaw.yml` run exists for the exact HEAD."*

### 2. Is `chainsaw-verify` a REQUIRED status check?

**Cannot be read directly** — branch-protection rules are not exposed by the available GitHub MCP tools. **Inferred: NOT required.** Evidence:

- **#149** (merged 2026-06-06, base `534a0ce` = the same old main the stack was built on) modified `terraform/management/acm-management.tf` and `helm.tf`. Its check runs are: Terraform plan / apply-and-verify, Unit tests, base+management fmt+validate. **There is NO `chainsaw-verify` check on #149 at all**, and it merged. (#149 touches no crossplane/chainsaw paths, so the verifier never fired — consistent with the path filter — and its absence did not block merge.)
- **#145**'s only check run is `Unit tests` (success). No `chainsaw-verify` (it touches no crossplane/chainsaw paths).
- #153/#154 likewise merged as ordinary merge-train commits.

Multiple PRs have merged with `chainsaw-verify` either absent or (historically, per #142's note) red. **Conclusion: treat `chainsaw-verify` as advisory.** *(Hypothesis, not API-confirmed: there is no required-status-check enforcing it.)* **Recommendation: attempt the merge; if GitHub blocks on a required check, dispatch `chainsaw.yml` on the exact HEAD and re-verify.**

### 3. Per-PR change inventory + chainsaw-warranting paths

Paths that warrant a chainsaw run per AGENTS §6.7/§6.8: `crossplane/**`, `tests/chainsaw/**`, plus the chainsaw-workflow files. The flagged GitOps dirs (`argocd/**`, `clusters/**`, `policies/**`) are ArgoCD-inert scaffolding here and do **not** match the verifier path filter.

- **#144 (trunk, 13 files):** `decisions/auto-007-scope-envelope.md`, `decisions/auto-008-spoke-gitops-delivery.md`, `docs/open-issues.md`, `docs/runbooks/argocd-sync-from-ci.md`, `retrospective/2026-06-05-148*` (report + ADR + 6 AGENTS-MD + 1 SKILL-SPEC), `run-summary.md`. **All docs/decisions/retro — no code, no crossplane/**, no tests/chainsaw/**.** Touches NONE of the chainsaw-warranting paths. (Its `chainsaw-verify` red is therefore purely a SHA-pin artifact.)
- **#145 (phase-3 spoke, 23 files):** `argocd/apps/spoke/{ingress-nginx,external-dns,hello}.yaml`, `argocd/projects/platform-spoke.yaml`, `platform-services/{external-dns,hello,ingress}/*`, `policies/audit/10-spoke-no-cluster-admin-binding.yaml`, `tests/e2e/spoke-egress-probe.yaml`, **`terraform/management/helm.tf` (modified)**, `tests/unit/run.sh` + 5 new `tests/unit/test_*.sh`, `ai/handoff.md`, `decisions/auto-008*`, `decisions/auto-009-phase3-live-completion-runbook.md`. **Touches `argocd/**`, `policies/**`, `terraform/management/helm.tf` — but NO `crossplane/**` and NO `tests/chainsaw/**`.** Does not match the chainsaw verifier path filter.
- **#146 (phase-6 workload1, 9 files):** `argocd/apps/workload1-cluster.yaml`, `argocd/apps/spoke/workload1-{ingress-nginx,external-dns,hello}.yaml`, `clusters/workload1/{00-namespace,workload-cluster}.yaml`, `platform-services/external-dns/workload1-values.yaml`, `tests/unit/run.sh`, `tests/unit/test_workload1_apps.sh`. Touches `argocd/**`, `clusters/**` — **no `crossplane/**`, no `tests/chainsaw/**`.**
- **#147 (phase-4 observability, 9 files):** `argocd/apps/spoke/observability-{kube-prometheus-stack,loki}.yaml`, `argocd/apps/spoke/observability-alloy-mgmt.yaml.todo` (parked, not synced), `argocd/projects/platform-spoke.yaml` (modified), `platform-services/observability/{alloy,kube-prometheus-stack,loki}/values.yaml`, `tests/unit/run.sh`, `tests/unit/test_observability_apps.sh`. Touches `argocd/**` — **no `crossplane/**`, no `tests/chainsaw/**`.**
- **#148 (phase-5 keycloak, 10 files):** `argocd/apps/spoke/keycloak.yaml`, `argocd/projects/platform-spoke.yaml` (modified), `clusters/platform/rbac/kc-k8s-{admins-cluster-admin,viewers-view}.yaml`, `docs/operations.md`, `platform-services/keycloak/{values.yaml,realm-platform-configmap.yaml,secrets/keycloak-secrets.yaml}`, `tests/unit/run.sh`, `tests/unit/test_keycloak_apps.sh`. Touches `argocd/**`, `clusters/**` — **no `crossplane/**`, no `tests/chainsaw/**`.**

**Verdict:** NONE of the five PRs touch `crossplane/**` or `tests/chainsaw/**`. Per the verifier's own path filter, **no chainsaw run is warranted by content** for any of them. The only place `chainsaw-verify` even appears is on #144 (a stale-SHA red), and it is non-blocking (finding 2).

### 4. Conflict risk vs current `main` (#149–#154)

All five stack branches were built on old main `534a0ce`. Recently-merged PRs that advanced main touched: `terraform/management/{eks.tf,helm.tf,acm-management.tf}` (#149), `scripts/composition-render.sh`, `tests/chainsaw/versions.env`, `scripts/sandbox-setup.sh`, `docs/open-issues.md` (#153), `decisions/*` + `docs/decisions/0004*` + `AGENTS.md` (#152/#154), `ai/handoff.md` / `argocd/apps/crossplane-resources.yaml` (#151).

- **#145 — `terraform/management/helm.tf` is the top conflict risk (confirmed).** Both #145 and the already-merged **#149** modify `helm.tf`. #149 rewrote the **ingress-nginx `aws-load-balancer-ssl-cert`** block to use `local.management_acm_certificate_arn`. #145's body says it narrows the **ExternalDNS `domainFilters`** in `helm.tf` from the whole zone to `management.`. I confirmed against current `main`'s `helm.tf`: the ExternalDNS block STILL reads `domainFilters[0] = var.domain` and `txtOwnerId = "k8-platform-mgmt"` — i.e. **#145's hub-filter narrowing is NOT yet on main**, and #145's diff was authored against the pre-#149 `helm.tf`. Expect a **textual merge conflict in `terraform/management/helm.tf`** (or at minimum a diff that re-touches lines #149 moved). This MUST be resolved by hand when #145 rebases onto current main. *Design note (hypothesis): #145's dual-ExternalDNS disjointness story assumes the hub filter is narrowed to `management.`; if the rebase silently drops that narrowing, the hub external-dns stays scoped to the whole zone and the disjointness invariant the phase-3/4/6 tests assert at the spoke level is weaker at the hub. Re-verify the hub `domainFilters`/`txtOwnerId` after resolving.*
- **#145 — `tests/unit/run.sh`** is appended-to by #145, #146, #147, #148 (each adds a `run_suite` line). Across the stack these are stacked on each other so they won't collide internally, but **all four also race any run.sh change on main**. No run.sh change landed in #149–#154, so low risk vs main; the in-stack ordering is fine.
- **#144 (trunk)** is docs/decisions/retro only. Risk areas vs main: `docs/open-issues.md` (also edited by #153/#151) and `decisions/auto-008*` (also added by #145 and possibly touched on main). **Possible conflict in `docs/open-issues.md`** and duplicate-add risk on `decisions/auto-008-spoke-gitops-delivery.md` (added by BOTH #144 and #145 — if main already has it via another merge, expect an add/add conflict). Re-check at merge time.
- **#146 / #147 / #148** touch only new files under `argocd/`, `clusters/`, `platform-services/`, plus `tests/unit/run.sh` and the shared `argocd/projects/platform-spoke.yaml`. **`argocd/projects/platform-spoke.yaml` is modified by #147 AND #148** (each appends different `sourceRepos`). They're stacked siblings off #145, so whichever merges second will need its `platform-spoke.yaml` sourceRepos addition rebased on top of the first — **expect a small conflict in `argocd/projects/platform-spoke.yaml` between #147 and #148** (both add lines to the same `sourceRepos:` list). None of these three touch files #149–#154 changed, so risk vs main is low; the contention is **intra-stack** (#147 vs #148 on platform-spoke.yaml; all four on run.sh).

---

## Merge-train procedure (in order)

General rule per finding 2: **attempt each merge; only dispatch chainsaw if a required check actually blocks.** Per finding 3, **no PR's content warrants a chainsaw run** (none touch `crossplane/**` or `tests/chainsaw/**`), so a chainsaw dispatch is expected to be needed for **none** of them — except as a fallback to green a stale `chainsaw-verify` on #144 *if and only if* it turns out to be a required check.

### Step 0 — Pre-flight
- Confirm `main` HEAD is `c3a6cb3` (the SHA #144 is currently based on). If main has advanced further, every "rebase onto main" below targets the new HEAD.
- Confirm CI green expectations: each PR should show `Unit tests` + `*— fmt + validate` green after rebase.

### Step 1 — Land #144 (trunk)
1. `update-branch` #144 onto `main` (it is already based on `c3a6cb3`; refresh if main moved). Watch for a conflict in `docs/open-issues.md` and an add/add on `decisions/auto-008-spoke-gitops-delivery.md`; resolve by hand if they appear.
2. Re-run checks. `Unit tests` + fmt/validate should be green.
3. **`chainsaw-verify` will be RED (stale SHA).** Content does not warrant chainsaw (docs-only). **Do NOT dispatch chainsaw** unless the merge is actually blocked by a required check. If blocked: dispatch `chainsaw.yml` against #144's exact HEAD, wait green, then re-run the verifier — but first confirm it is genuinely required (it is almost certainly not; #149/#145 merged without it).
4. Merge #144 into `main`.

### Step 2 — Land #145 (phase-3 spoke) — THE conflict-bearing step
1. After #144 merges, GitHub auto-retargets #145's base to `main`.
2. `update-branch` #145 onto `main`. **Expect a merge conflict in `terraform/management/helm.tf`** (vs #149). Resolve by:
   - keeping #149's ingress-nginx `aws-load-balancer-ssl-cert = local.management_acm_certificate_arn` block, AND
   - re-applying #145's ExternalDNS hub-filter narrowing (`domainFilters[0]` → `management.${var.domain}`, and whatever `txtOwnerId`/`txtPrefix` change #145 intends) on top of the current block.
   - After resolving, **verify the hub external-dns is narrowed to `management.`** (run the disjoint-filter unit test locally if possible) so the dual-ExternalDNS invariant holds.
   - Also reconcile `tests/unit/run.sh` (#145 appends a `run_suite` line) and any `docs/open-issues.md`/`decisions/auto-008*` overlap with what #144 brought in.
3. Re-run checks; `Unit tests` (now including the 5 new phase-3 suites) + management fmt/validate must be green. **No chainsaw needed** (no crossplane/chainsaw paths).
4. Merge #145 into `main`.

### Step 3 — Land #146 / #147 / #148 (phases 6 / 4 / 5)
These three are independent siblings off #145; after #145 merges, all three auto-retarget to `main`. Land them one at a time. **Intra-stack contention to expect:**
- **#147 and #148 both append to `argocd/projects/platform-spoke.yaml` `sourceRepos`.** Whichever you merge second must rebase its added line(s) on top of the first's. Resolve by keeping BOTH additions (prometheus-community + grafana from #147; bitnami from #148).
- **All three append to `tests/unit/run.sh`** — keep all `run_suite` lines.

Suggested order (any order works; this minimizes rework):
1. `update-branch` **#146** onto `main`; resolve `tests/unit/run.sh` append if needed; green checks (unit tests incl. `test_workload1_apps.sh`); merge.
2. `update-branch` **#147** onto `main`; resolve `tests/unit/run.sh` and (if #148 not yet merged, none) `platform-spoke.yaml`; green checks; merge.
3. `update-branch` **#148** onto `main`; **resolve `argocd/projects/platform-spoke.yaml`** (keep #147's + #148's sourceRepos) and `tests/unit/run.sh`; green checks; merge.

For each: **no chainsaw dispatch required** (none touch `crossplane/**` or `tests/chainsaw/**`); merge on green `Unit tests` + validate.

### Post-merge
- Confirm `main` `tests/unit/run.sh` lists all four new suites and `argocd/projects/platform-spoke.yaml` carries all four sourceRepos additions (ingress-nginx + external-dns base, prometheus-community, grafana, bitnami).
- These are ArgoCD-inert scaffolding (apps are unsynced / `.todo` / manual-sync); merging creates NO live AWS resources. Live coupling (spoke registration, XR sync, Keycloak DB, Alloy hub-addons project per #154) is deferred and out of scope for the landing.

---

## Contention note — live track on AWS account 211125540973

A concurrent live track is running phase-1/2/3 terraform + chainsaw on AWS account **211125540973**. Recommendation: **the stack landing does NOT need to wait, and should NOT dispatch any chainsaw of its own.**

- None of #144–#148 touch `crossplane/**` or `tests/chainsaw/**`, so **no chainsaw run is warranted** by their content (finding 3). There is nothing to contend over.
- A `chainsaw.yml` dispatch would run against a kind cluster in CI, not against account 211125540973 directly — but the project's chainsaw harness exercises real ASM/Crossplane managed resources and historically shares the live account; dispatching one concurrently with the live phase-1/2/3 run risks **ASM-secret / managed-resource cleanup collisions** (cf. OI-2026-05-28-1 cleanup-trap). Since no stack PR needs chainsaw, **avoid dispatching chainsaw for the merge train at all** while the live track is active.
- If `chainsaw-verify` on #144 turns out to be a hard required check (unlikely per finding 2) and a dispatch becomes unavoidable, **wait for the live phase-1/2/3 chainsaw to finish first** to avoid concurrent runs against the shared account, then dispatch on #144's settled HEAD.
- The terraform/management `helm.tf` change in #145 is the one piece of the stack that, once merged and later applied live, interacts with the management cluster's ExternalDNS scoping — but merging it changes no live state (apply is a separate, operator-driven step). No live-track coordination is required to *merge*; coordinate only when the management module is next applied.
