# Spec and Repository Structure — Forensic Evidence

**Scope:** 722 commits, 2026-05-02 through 2026-06-10  
**Purpose:** Agent-facing fact record. No recommendations. All claims tagged.

---

## Headline Facts (10 bullets)

1. [FACT] The spec corpus has **two parallel vocabularies for the same build stages**: `ai/DESIGN.md` and `ai/REQUIREMENTS.md` call them "Iterations 0–6"; `ai/testing-guidelines.md` (introduced 2026-05-17, commit `41c30dc`) calls them "phases 0–N". Line 53 of `testing-guidelines.md` bridges them: *"phases (iterations 0–6)"* — a parenthetical that is the sole explicit vocabulary mapping.

2. [FACT] **`ai/DESIGN.md` Iteration 3 does not specify who creates the ArgoCD cluster Secret** for the spoke cluster. The spec says "ArgoCD ApplicationSet targeting the platform cluster" with no mechanism for how ArgoCD learns the cluster's endpoint/CA. This gap surfaced as `OI-2026-06-07-1` (open-issues.md:106): "spoke ArgoCD cluster Secret has no GitOps form" — manually bootstrapped via REST API in auto-012 and again in auto-016.

3. [FACT] **`XSpokeAccess` XRD is not mentioned anywhere in `ai/DESIGN.md` or `ai/REQUIREMENTS.md`**, yet it was built as a phase-3 necessity (commit `81f94d6`, 2026-06-06). The spec names only `PlatformSecret` and `PlatformCluster` XRDs (REQUIREMENTS.md:96–99, DESIGN.md:213–214). A third XRD was invented under implementation pressure with no spec coverage.

4. [FACT] **A Crossplane v1→v2 major-version mismatch blocked all chainsaw tests** for 5+ days (2026-05-25 through 2026-05-26). The spec never specified provider versions or a version-pinning contract. 29 files had to be migrated (00-situation.md:119). Directory `ai/crossplane-v1-v2-un-fuckify/` (21 files, 4,314 lines) records the full incident.

5. [FACT] **The root directory has 16 ephemeral session artifacts at HEAD**: 11 `run-summary-*` files, 1 `run-envelope-*`, 1 `overnight-summary.md`, 1 `handoff-followups-2026-05-28.md`, 1 `SUBSTRATE-READINESS.md`, 1 `run-summary.md`. None of these paths appear in any spec or README directory listing.

6. [FACT] **There are two separate `decisions/` trees**: `decisions/` (root, 19 files, auto-NNN scope-envelopes + ADRs) and `docs/decisions/` (9 numbered ADRs, 0001–0009). Neither README nor DESIGN.md documents both trees or their relationship. `ai/DESIGN.md` only mentions `docs/decisions/` in its repo structure diagram.

7. [FACT] **`docs/iterations/` is an empty stub** (only `.gitkeep`), committed in the initial scaffold (commit `3c08966`, 2026-05-03) and never populated. `ai/DESIGN.md` section 3 describes it as "Per-iteration design and blog notes."

8. [FACT] **`docs/open-issues.md` has 8 open items and 13 resolved items** (audited 2026-06-09). The 8 open items include 2 NOW-BLOCKING issues (OI-2026-06-07-2: overlay/selfHeal conflict; OI-2026-06-07-3: ELB subnet tags) that both recurred in auto-016. The file is 1,064 lines. Introduced 2026-05-28.

9. [FACT] **`docs/testing-debt-burndown.md` was created 2026-06-08** in response to owner direction ("clear this list before any new implementation work"). All 5 burndown items are marked `✅ DONE`. However, `ai/handoff.md` (line 12–19) contradicts this: "auto-016 declared progress but clean-build-tested NONE of it."

10. [FACT] **`ai/specs/` contains exactly one file** (`ext-github-design.md`, 32,673 bytes), created 2026-05-23. `AGENTS.md §2` designates `ai/specs/` as authoritative for scoped design work. The brainstorming specs live in `ai/brainstorming/specs/` (77 files). These are distinct paths with no cross-reference.

---

## 1. Spec Corpus Inventory

| Document | Lines | Introduced | Last Meaningful Update | Territory |
|----------|-------|------------|----------------------|-----------|
| `ai/DESIGN.md` | 552 | 2026-05-03 (`3c08966`) | 2026-06-05 (`aedee63`) | Architecture rationale, ADRs 001–008, repo structure, Iterations 0–6 component lists |
| `ai/REQUIREMENTS.md` | 213 | 2026-05-03 (`3c08966`) | 2026-06-05 (`aedee63`) | Functional REQ-* entries per iteration, NFRs, constraints |
| `ai/TESTING-PLAN.md` | 140 | 2026-05-23 (`452e228`) | 2026-05-23 (`476d0d1`) | 4-layer test matrix, Chainsaw intent, bug-class registry |
| `ai/PHASE-2-LIFECYCLE-PLAN.md` | 243 | 2026-05-24 (`7732709`) | 2026-05-25 (`7bb707c`) | Runbook: phase-2 verify/teardown/rebuild steps (inline bash) |
| `ai/testing-guidelines.md` | ~350 | 2026-05-17 (`41c30dc`) | 2026-05-25 (multiple) | Phase state model, "work on phase N" procedure, CI dispatch |
| `ai/handoff.md` | ~800 | 2026-05-17 | 2026-06-09 (auto-016) | Current-session state, quickstart, open work; updated every session |
| `ai/specs/ext-github-design.md` | 32,673 | 2026-05-23 (`0fd01d3`) | 2026-05-23 | External GitHub API bridge design (single topic) |
| `ai/brainstorming/specs/` | 21,778 (total) | 2026-05-25 | 2026-05-25 | 50+ individual SPEC-* files (tool/feature micro-specs) |
| `ai/crossplane-v1-v2-un-fuckify/` | 4,314 (total) | 2026-05-26 (`a7c6efd`) | 2026-05-26 | v1→v2 migration situation + impact + plans |
| `docs/decisions/` | 9 ADRs | 2026-05-26 (`60c26e1`) | 2026-06-08 | Numbered ADRs 0001–0009 (architecture + operating policy) |
| `decisions/` | 19 files | 2026-05-25 (`6a9c1af`) | 2026-06-08 | auto-NNN scope-envelopes, session plans, decision notes |
| `ai/archive/` | 2 files | 2026-05-03 | 2026-05-03 | `testing-overview.md` (superseded), README |
| `ai/PHASE-2-LIFECYCLE-PLAN.md` | 243 | 2026-05-24 | 2026-05-25 | Superseded by inline runbook |

**Territory overlap:**

| Area | Documents in conflict |
|------|-----------------------|
| Test strategy | `ai/TESTING-PLAN.md` (4-layer matrix) vs `ai/testing-guidelines.md` (phase-by-phase CI procedure) — complementary but no explicit cross-reference |
| Architecture decisions | `ai/DESIGN.md` §7 (ADRs 001–008, inline) vs `docs/decisions/` (0001–0009, numbered files) — DESIGN.md ADR-001 through 008 appear to be the same decisions as `docs/decisions/0001–0009` by topic, but are presented differently and neither document cross-references the other [OPEN: confirm 1:1 mapping] |
| Per-session decisions | `decisions/auto-NNN-*.md` (root) vs `planning/test-overhaul/decisions/` — both accumulate session decisions; structure differs by era |

---

## 2. Layer Interface Analysis

Architecture chain: `Terraform(mgmt)` → `ArgoCD hub` → `Crossplane XRDs` → `platform-services` → `workload clusters`

### Boundary 1: Terraform → ArgoCD

**Pinned in spec:** Terraform installs ArgoCD via Helm (REQUIREMENTS.md:REQ-MGMT-01, DESIGN.md Iteration 1). Management cluster name: `k8-platform-mgmt` [FACT: ai/PHASE-2-LIFECYCLE-PLAN.md:26]. ArgoCD accessible at `argocd.management.<domain>`.

**Unspecified:** No spec entry for who creates the initial ArgoCD `Application` that points at the repo (the `bootstrap` app-of-apps). README.md line 81: *"After `apply`, ArgoCD takes over."* [FACT: README.md:81] — this is hand-waving. The mechanism (Terraform `terraform_data.argocd_bootstrap` resource) was discovered at implementation and is referenced in `ai/PHASE-2-LIFECYCLE-PLAN.md:17` but not in `ai/DESIGN.md` or `ai/REQUIREMENTS.md`.

**Interface ambiguity evidence:** Commit `89941cd` (2026-05-23): `fix(argocd): set IRSA annotation on server SA, not top-level SA` — IRSA ownership between Helm chart top-level SA and ArgoCD server SA was unclear and required a fix after deployment.

### Boundary 2: ArgoCD hub → Crossplane XRDs

**Pinned in spec:** ArgoCD Application named `crossplane-resources` manages `crossplane/` path (PHASE-2-LIFECYCLE-PLAN.md:11). App named `management-cluster-config` manages `clusters/management/`. Sync-wave ordering: `-10` before `0` (PHASE-2-LIFECYCLE-PLAN.md:229).

**Unspecified:** No spec entry for the `ClusterProviderConfig` object required by Crossplane v2. Added as `fix(crossplane): add shared ClusterProviderConfig/default (IRSA) via GitOps` (commit `a7a3197`, 2026-06-06). This was a phase-3 blocker undiscovered until live testing.

**Interface ambiguity evidence:** Commit `f737e03` (2026-06-06): `fix(crossplane): child-provider IRSA via runtimeConfigRef (Option A)` — how the Crossplane AWS child-provider acquires its IRSA annotation was not specified; required an adversarial decision brief (`decisions/auto-011-child-provider-irsa.md`).

### Boundary 3: Crossplane XRDs → ArgoCD spoke registration

**Pinned in spec:** REQUIREMENTS.md REQ-PLAT-02: *"ArgoCD on the management cluster must deploy all platform services to the platform services cluster using a hub-spoke model."* No further mechanism specified.

**Unspecified — concrete gap:** The spec does not specify how the ArgoCD cluster Secret (endpoint + CA data + IRSA config) is created for spoke clusters. DESIGN.md Iteration 3 lists `XPlatformCluster` as creating EKS + node group + IRSA + ACM cert. It does not mention a `writeConnectionSecretToRef` or provider-kubernetes Object that assembles the ArgoCD cluster Secret. This gap caused `OI-2026-06-07-1` (open-issues.md:106–134): cluster Secret was created manually via ArgoCD REST API in auto-012 and auto-016; has no durable GitOps form at HEAD.

**Quote:** `open-issues.md:118` — *"The endpoint+CA are account-ephemeral (§8.1, uncommittable) and the EKS Cluster MR publishes NO connection secret (writeConnectionSecretToRef empty)"*

### Boundary 4: Crossplane XRDs → platform-services (spoke app config)

**Unspecified — blocking gap:** Spoke applications (ingress-nginx, ExternalDNS, hello) require per-account values: domain, ACM cert ARN, ExternalDNS role ARN. The spec does not specify how spoke apps receive these values. DESIGN.md Iteration 3 says apps deploy via ApplicationSet with no mechanism for value injection.

**Evidence:** `OI-2026-06-07-2` (open-issues.md:138–167): PLACEHOLDER Helm values in committed manifests revert when `bootstrap` selfHeal fires. Workaround: pause bootstrap. ADR `docs/decisions/0005` decided a cluster-facts ConfigMap approach — not yet implemented as of auto-016 HEAD. Status: "NOW BLOCKING" (open-issues.md:20).

**Quote:** `open-issues.md:151` — *"The values are account-ephemeral (§8.1) so they cannot be committed to satisfy bootstrap."*

### Boundary 5: Crossplane compositions → AWS (IAM/IRSA)

**Unspecified scope:** `ai/DESIGN.md §5.1` lists four IRSA roles at a high level (Crossplane provider, ESO, ExternalDNS, ACM/Route53). No IAM action list, no resource ARN scope. Multiple commits evidence iterative narrowing: `OI-2026-06-08-1` (IAM `Resource:"*"` tightening), PRs #203/#211/#212/#213. IAM policy was discovered/narrowed reactively over auto-013 through auto-016 runs.

---

## 3. Directory Structure Consistency

### README/DESIGN.md Claimed Structure vs Actual

`ai/DESIGN.md §3` and `README.md` claim this top-level structure:

```
terraform/base  terraform/management  argocd/  crossplane/  clusters/
platform-services/  docs/decisions  docs/iterations  docs/diagrams
```

**Actual top-level additions not in spec:**

| Path | Type | Purpose | In spec? |
|------|------|---------|----------|
| `decisions/` | directory | auto-NNN scope-envelopes + session ADRs | No |
| `retrospective/` | directory | 46 session retrospectives | No |
| `planning/` | directory | test-overhaul adversarial plans | No |
| `summary/` | directory | 4 early session summaries | No |
| `logs/` | directory | CI log stubs | No |
| `policies/` | directory | Kyverno audit policies | No |
| `kubeconform-schemas/` | directory | Vendored CRD schemas | No |
| `ai/brainstorming/` | directory | Brainstorm JSON + 77 SPEC files | No |
| `ai/crossplane-v1-v2-un-fuckify/` | directory | v1→v2 migration docs | No |
| `ai/specs/` | directory | Authoritative per-feature specs | No |
| `run-summary-*.md` (11 files) | root files | Session run summaries | No |
| `run-envelope-auto-016.md` | root file | Session scope envelope | No |
| `overnight-summary.md` | root file | Overnight session summary | No |
| `handoff-followups-2026-05-28.md` | root file | Session carry-over notes | No |
| `SUBSTRATE-READINESS.md` | root file | Clean-build gate checklist | No |
| `run-summary.md` | root file | Single run summary | No |

### Root-Level Clutter Inventory

16 non-spec ephemeral files at root. Named by two conventions:
- **Date-named era:** `run-summary-2026-05-25.md`, `run-summary-2026-05-26.md`, `run-summary-2026-05-28.md` (3 files)
- **auto-NNN era:** `run-summary-auto-009.md` through `run-summary-auto-016.md` (8 files), `run-envelope-auto-016.md` (1 file)
- **One-off:** `overnight-summary.md`, `handoff-followups-2026-05-28.md`, `run-summary.md`, `SUBSTRATE-READINESS.md`

The naming convention shifted from date-based to `auto-NNN` circa 2026-05-28 with no documented rule change. [FACT: git log timestamps on run-summary files]

### tests/ Subtree Taxonomy

| Subtree | Files | Description | In TESTING-PLAN.md? |
|---------|-------|-------------|---------------------|
| `tests/unit/` | 74 .sh files | Helm render, IRSA, IAM, policy lint, XRD contracts | Yes (Layer 1) |
| `tests/integration/` | 16 .sh files | Live cluster tests 01–13 | Yes (Layer 3) |
| `tests/chainsaw/` | 22 YAML files | Crossplane XRD scenarios in kind | Yes (Layer 4) |
| `tests/live/` | 34 .sh files | Per-resource AWS behavioral checks | No (added auto-014+) |
| `tests/e2e/` | 5 .sh files | Pre-condition + route53/state checks | Partial |
| `tests/coverage/` | 6 files | Coverage registry + deriver script | No |
| `tests/fixtures/` | 1 file | Pre-migration composition | No |
| `tests/lib/` | 1 file | Shared assert helpers | No |

**Undocumented subtrees:** `tests/live/` (introduced auto-014, PR #190) and `tests/coverage/` appear in no spec document. `ai/TESTING-PLAN.md` describes 4 layers; the live suite is a 5th layer.

### Parallel/Competing Trees

| Competing pair | Relationship |
|----------------|-------------|
| `crossplane/xrds/` vs `crossplane/compositions/` | Complementary (XRD + Composition per resource); consistent naming |
| `clusters/management/` vs `clusters/platform/` vs `clusters/workload1/` | Per-cluster overlays; `clusters/workload-template/` also present (template vs live naming mixed) |
| `decisions/` (root) vs `docs/decisions/` | [FACT] Two decisions directories. Root has auto-NNN session operational docs; `docs/decisions/` has numbered architectural ADRs. DESIGN.md §3 only claims `docs/decisions/`. |
| `ai/brainstorming/specs/` vs `ai/specs/` | `AGENTS.md §2` designates `ai/specs/` as authoritative. `ai/brainstorming/specs/` has 50+ SPEC-* files (feature-level specs). `ai/specs/` has 1 file. No document explains the relationship or when a spec graduates from brainstorming to authoritative. |

---

## 4. Vocabulary: Iterations vs Phases

| Document | Vocabulary used | Date introduced |
|----------|-----------------|-----------------|
| `ai/DESIGN.md` | "Iterations 0–6" | 2026-05-03 |
| `ai/REQUIREMENTS.md` | "Iteration 0–6" in section headers | 2026-05-03 |
| `ai/testing-guidelines.md` | "phases (iterations 0–6)" | 2026-05-17 |
| `AGENTS.md §5` | "phases 0–6" | 2026-05-17 |
| `ai/PHASE-2-LIFECYCLE-PLAN.md` | "phase 2" throughout | 2026-05-24 |
| Commit messages (2026-05-23+) | "phase 1", "phase 2", etc. | 2026-05-23 (`9bd264d`) |
| `decisions/auto-004-scope-envelope.md` | explicitly bridges: "phase 2 = DESIGN.md §Iteration 2" | 2026-05-25 |

**Switch point:** [FACT] First commit using "phase" vocabulary for build stages: `9bd264d` (2026-05-23). `ai/DESIGN.md` continues to use "Iteration" throughout (never updated). The two vocabularies coexist in all documentation from 2026-05-17 onward. `decisions/auto-004-scope-envelope.md` contains the only explicit bridge mapping: *"Phase 2 = Crossplane Foundations (DESIGN.md §Iteration 2)"*.

**Phase 1–5 in later docs ≠ Iterations 1–5:** `ai/DESIGN.md` has Iterations 1–6 (management cluster through workload cluster). The `decisions/` era and commit messages use "phase 3" to mean the platform services cluster (= Iteration 3), "phase 4" for observability (= Iteration 4), "phase 5" for authentication (= Iteration 5). Numbering is consistent; vocabulary is not.

**`ai/PHASE-2-LIFECYCLE-PLAN.md` title anomaly:** The file title says "Phase 2 lifecycle plan" using the later phase vocabulary, while `ai/DESIGN.md` §4 calls the same content "Iteration 2: Crossplane Foundations." [FACT: file names, section headers]

---

## 5. ai/crossplane-v1-v2-un-fuckify/

**Contents:** 21 files, 4,314 lines. Created entirely on 2026-05-26 (commits `a7c6efd` through `39b964d`).

**Structure:**
- `00-situation.md` (authoritative root-cause analysis)
- `10-impact-*.md` (4 impact analyses: session tools, production manifests, terraform, test infra)
- `20-plan-SEG-[1-5]-*.md` (5 migration segment plans)
- `30-review-SEG-[1-5]-R1[A/B]-*.md` (10 adversarial reviews)
- `40-final-plan.md` (synthesis)

**Event recorded:** On 2026-05-25, every `tests/chainsaw/platform-secret/*` scenario timed out. Root cause: Crossplane 2.3.0 (v2) installed with Upbound provider-family-aws v1.12.0 (v1). Providers install and report `Healthy=True` but the Observe path silently fails — AWS Secrets Manager secret is created but Crossplane loses track of it. [FACT: 00-situation.md §2–3]

**Scope of impact:** 29 files using `aws.upbound.io` (v1 API group) required migration to `aws.m.upbound.io` (v2). Plus 53 JSON Schema files under `kubeconform-schemas/`. [FACT: 00-situation.md:119–158]

**Timeline:** v1.12.0 providers first pinned (inferred from initial scaffold); v2.5.0 migration planned 2026-05-26; actual migration executed via autonomous runs auto-004/005 spanning 2026-05-25 through 2026-05-28. [FACT: git log dates on crossplane v1-v2 commits and run summaries]

**Key finding from `00-situation.md §4`:** Migration required removing `claimNames:` blocks from XRDs (Crossplane v2 removes the claim/XR separation), changing all `providerConfigRef` entries to include `kind:` field, and removing `deletionPolicy` from namespaced MRs.

---

## 6. docs/open-issues.md and docs/testing-debt-burndown.md

### open-issues.md

| Attribute | Value |
|-----------|-------|
| Size | 1,064 lines |
| Introduced | 2026-05-28 (`392989f`) |
| Last updated | 2026-06-09 (`a15c7b5`) |
| Total OI entries | ~19 named issues |
| Truly open (active work outstanding) | 8 (`OI-2026-06-07-{1,2,3,4,5,6,7,8}`) |
| In-flight (open, closing) | 3 (`OI-2026-06-09-1`, `OI-2026-06-08-1`, `OI-2026-06-08-2`) |
| Environmental/mitigated | 2 |
| Resolved (retained for rationale) | ~13 |

**Blocking open items at HEAD:**
- `OI-2026-06-07-2`: Placeholder overlays reverted by bootstrap selfHeal → hello e2e unreachable. Decision made (ADR-0005 ConfigMap), not implemented.
- `OI-2026-06-07-3`: Shared-VPC ELB subnet tags missing for spoke → NLB can't provision. Live-fixed per-session; no durable terraform fix.
- `OI-2026-06-07-4`: Hub→spoke API SG 443 rule has no durable form. Live-fixed per-session; Composition fix owed.
- `OI-2026-06-07-1`: ArgoCD spoke cluster Secret has no GitOps form. Manually bootstrapped each session via REST API.

### testing-debt-burndown.md

| Attribute | Value |
|-----------|-------|
| Size | 115 lines |
| Introduced | 2026-06-08 (`391376b`) |
| Last updated | 2026-06-08 (`c707c86`) |
| Items | 5 items (1a/1b merged as "1"), all marked ✅ DONE |

**Contradiction:** `ai/handoff.md:12–19` (updated 2026-06-09, after burndown was marked done) states: *"auto-016 declared progress but clean-build-tested NONE of it. Every 'fix' below was validated by a live hand-workaround, not by the committed artifact from a clean build, or not tested at all. NOTHING here is 'done' — every item is `pending clean-build verification`."* [FACT: ai/handoff.md:15–16]

---

## Appendix: Spec Reference Quick-Map

| If an agent needs to know... | Read... |
|-----------------------------|---------|
| Why each component was chosen | `ai/DESIGN.md §2` (technology decisions) |
| What must be built per iteration | `ai/REQUIREMENTS.md §4` (REQ-* entries) |
| How to execute a phase in CI | `ai/testing-guidelines.md §3` |
| Current environment state | `ai/handoff.md` (Environment State block) |
| Test layer ownership | `ai/TESTING-PLAN.md` (4-layer matrix) |
| Per-session scope | `decisions/auto-NNN-scope-envelope.md` |
| Numbered architecture decisions | `docs/decisions/0001–0009` |
| Open undiagnosed failures | `docs/open-issues.md` |
| Technical debt | `docs/testing-debt-burndown.md` |
| Crossplane v1→v2 migration | `ai/crossplane-v1-v2-un-fuckify/00-situation.md` |
| Specific tool/feature micro-specs | `ai/brainstorming/specs/SPEC-*.md` |
| Authoritative in-flight design | `ai/specs/` (currently: `ext-github-design.md` only) |
