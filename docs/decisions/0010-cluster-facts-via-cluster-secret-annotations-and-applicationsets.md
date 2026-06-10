# 0010 — Cluster facts reach spoke Applications via cluster-Secret annotations templated by ApplicationSets

- **Status**: PROPOSED (round-1 adversarial review applied; owner ratification pending)
- **Date**: 2026-06-10
- **Closes**: OI-2026-06-07-2 (the SUBSTRATE-READINESS keystone, row 4) — mechanism
  decision deferred by the 2026-06-07 resolution ("decision brief → implement")
- **Relates**: ADR-0005 (ESO baseline; cluster-facts corollary), OI-2026-06-07-1
  (durable spoke registration Secret — the producer half), auto-008 §5 (which
  already designed the `k8-platform.io/certificate-arn` cluster-Secret annotation)

## Context

Nine spoke Applications (`argocd/apps/spoke/*.yaml`) carry committed placeholders
that were designed to be "overlaid at registration" with account-ephemeral values.
The `bootstrap` app-of-apps (selfHeal: true) manages those Application objects from
`main`, so it reverts every live overlay within its reconcile interval; the values
are account-ephemeral (archived AGENTS v1 §8.1) so they can never be committed to
satisfy it. This is the keystone blocker: the spoke NLB never gets a valid cert,
`hello.platform.<domain>` is unreachable, and every bring-up hand-fights bootstrap.

The facts involved, and their authoritative producers (all hub-side, all already
built):

| Fact | Producer (exists today) | Consumers |
|---|---|---|
| `domain` | terraform discovery → `cluster-network` EnvironmentConfig (`crossplane-phase3.tf`) | hello, keycloak, external-dns, kube-prometheus-stack (grafana host), hub alloy (remote-write/Loki URLs), workload1 mirrors |
| `certificate-arn` | `XPlatformCluster` Composition → `status.certificateArn` | ingress-nginx (NLB Service annotation), workload1 mirror |
| `external-dns-role-arn` | `XSpokeAccess` Composition (IRSA role MR) | external-dns SA annotation, workload1 mirror |
| `region` | terraform var / EnvironmentConfig | external-dns env |

The 2026-06-07 resolution set the principle (facts come from the cluster
abstraction, per-cluster, not per-app hand overlays; workloads stay
cloud-agnostic) and named a "per-cluster ConfigMap" as the carrier, with the
mechanism brief deferred. Tree-grounding shows a literal
ConfigMap-read-by-add-ons cannot carry two of the four facts: the cert ARN is a
**Service annotation** (`service.beta.kubernetes.io/aws-load-balancer-ssl-cert`)
and the role ARN is a **ServiceAccount annotation** — chart-rendered fields that
cannot read ConfigMaps at runtime; making them do so would require a mutating
webhook (Kyverno here is deliberately audit-only) or in-cluster cert discovery
(AWS LBC discovers certs for ALB/Ingress, not for NLB Services).

## Decision

**Carrier:** the per-cluster facts ride the ArgoCD **cluster Secret** for that
cluster — ArgoCD's native per-cluster object, already planned as the durable
registration artifact (OI-2026-06-07-1) and already carrying one fact annotation
in the auto-008 design. Contract (all required):

- labels: `k8-platform.io/cluster-role: spoke`, `k8-platform.io/short-name: <prefix>`
  (e.g. `spoke`, `workload1`)
- annotations: `k8-platform.io/domain`, `k8-platform.io/certificate-arn`,
  `k8-platform.io/external-dns-role-arn`, `k8-platform.io/region`

**Consumers:** the nine per-app Applications are replaced by **ApplicationSets**
(`goTemplate: true`) using the **cluster generator** selecting on
`k8-platform.io/cluster-role: spoke`. Templates inject only the facts each
add-on genuinely needs into `helm.valuesObject`; workload apps stay
cloud-agnostic (`hello` receives `domain` only — no ARNs, no region). Generated
Application names preserve today's names via the `short-name` label
(`spoke-hello`, …), keeping PR #210's live check and the AppProject scoping
valid. The workload1-* mirror files collapse into the same ApplicationSets — the
phase-6 "ApplicationSet refactor" arrives as a by-product, driven by a second
labeled cluster Secret. The hub-destination alloy agent keeps `destination` =
in-cluster hub but templates its spoke-derived URLs from the same generator.

**Producer phasing:**
- **PR-1 (this change, static-only):** the ApplicationSets + contract + tests.
  Inertness semantics are preserved exactly: with no labeled cluster Secret the
  generator produces zero Applications, as the per-app files were inert before
  registration. Touches `argocd/**` and `tests/**` only.
- **PR-2 (seam #5, the build-session change):** the durable registration Secret
  produced from committed source — the provisioning path assembles connection
  facts + these annotations (per ADR-0005, ESO `target.template` builds the
  caData-in-JSON `config`; the same template stamps the labels/annotations from
  the pushed facts). That PR touches `crossplane/**`/`terraform/management/**`
  and correctly trips the live-evidence gate; the clean build validates both
  halves together (SUBSTRATE-READINESS rows 4+5).

## Alternatives considered

- **Literal per-cluster ConfigMap read by add-ons** (the resolution's wording):
  rejected on tree-grounded feasibility — Service/SA annotations cannot read
  ConfigMaps; would force a mutating webhook into an audit-only posture. The
  principle it encoded (cluster abstraction owns the facts; no per-app hand
  overlays; cloud-agnostic workloads) is fully preserved by this decision.
- **bootstrap `ignoreDifferences` on helm value fields** (candidate 2): keeps the
  banned pattern — values still need a live hand actor every bring-up, which the
  done-contract forbids; nothing converges from source. Rejected.
- **ApplicationSet plugin generator reading a ConfigMap**: requires deploying and
  operating a plugin sidecar service; strictly heavier than the built-in cluster
  generator for the same data. Rejected.
- **Keep plain Applications, template values some other way**: Applications have
  no templating mechanism; only ApplicationSets do. Rejected on fact.

## Consequences

- The selfHeal fight disappears structurally: everything ArgoCD manages is in
  git; everything account-specific lives on the in-cluster Secret no git
  controller reverts. Bootstrap is never paused.
- The registration Secret becomes a **load-bearing interface** with a named
  contract (the L23 boundary-contract discipline applied to the D1 hole that
  caused this blocker). Contract enforced by unit lint both directions:
  ApplicationSets may only reference contract keys; the producer (PR-2) must
  emit exactly the contract keys.
- The ApplicationSet controller becomes load-bearing on the hub (it ships
  enabled in the pinned argo-cd chart; no install change needed).
- `kubeconform-schemas/argoproj.io/` gains `applicationset_v1alpha1.json`;
  `tests/unit/test_spoke_apps.sh` and peers are updated for the new kind.
- Risk accepted: ApplicationSet templating errors surface at generation time on
  the hub, not at PR time — mitigated by kubeconform + a template/contract lint
  + the live hello e2e check (PR #210) which fails if the chain breaks.

## Verification

Static (PR-1): kubeconform with the ApplicationSet schema; updated spoke-app
unit tests; a contract lint (ApplicationSets ↔ contract keys; no
`OVERLAID-AT-REGISTRATION` markers remain under `argocd/apps/spoke/`);
`test_spoke_values_no_ephemeral.sh` unchanged (templates are not literals).
Live (PR-2 + build session): clean bring-up from committed source → generated
apps converge → `hello.platform.<domain>` 200 via the PR #210 hard check →
SUBSTRATE-READINESS rows 4+5 evidence columns filled by run ID.
