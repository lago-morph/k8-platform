# 0010 — Cluster facts reach spoke Applications via cluster-Secret annotations templated by ApplicationSets

- **Status**: PROPOSED (round-1 adversarial review folded in — 2 reviewers, 5 BLOCKER
  + 7 MAJOR findings addressed, reviews in `planning/adr-0010-cluster-facts/`;
  owner ratification pending)
- **Date**: 2026-06-10
- **Closes**: OI-2026-06-07-2 (the SUBSTRATE-READINESS keystone, row 4)
- **Supersedes / amends**: the **cluster-facts ConfigMap corollary of ADR-0005**
  (its ESO decisions stand untouched). ADR-0005 named "a per-cluster ConfigMap of
  cluster facts" as the carrier; this ADR replaces that carrier (see Alternatives
  for why), and this PR updates the pointers in `SUBSTRATE-READINESS.md` row 4 and
  the `docs/open-issues.md` OI-2026-06-07-2 entry.
- **Reverses**: auto-008's reviewer-F1 rejection of the ApplicationSet cluster
  generator (rejected then for the accidentally-target-the-hub hazard; new
  rationale below under "Why the generator is now safe").
- **Relates**: OI-2026-06-07-1 (durable registration Secret — the producer half,
  still an OPEN blocker with its own unresolved mechanism fork; see Producer).

## Context

`argocd/apps/spoke/` holds ten files: eight spoke-destination Applications that
carry committed placeholders "overlaid at registration" with account-ephemeral
values, one spoke app with no ephemeral values (loki), and one hub-destination
app (the alloy agent) that needs spoke-derived URLs. The `bootstrap` app-of-apps
(selfHeal: true) manages all of them from `main` and reverts every live overlay
within its reconcile interval; the values are account-ephemeral so they can never
be committed. This is the keystone blocker: the spoke NLB never gets a valid
cert, `hello.platform.<domain>` is unreachable, and every bring-up hand-fights
bootstrap.

**The facts, their producers, and their per-cluster nature.** Every overlay
reduces to five per-cluster facts. Facts are **per-Secret complete**: each spoke
cluster's Secret carries its own full set (workload1's cert ARN / role ARN /
subdomain are genuinely different values produced by its own XPlatformCluster +
XSpokeAccess pair).

| Fact (annotation key, `k8-platform.io/…`) | Producer | Verified source |
|---|---|---|
| `domain` | terraform discovery → `cluster-network` EnvironmentConfig | `crossplane-phase3.tf:170` |
| `subdomain` | XR spec (`spec.dns.subdomain`); auto-008 already designed it as a Secret annotation | `platform-cluster.yaml` env patch; auto-008 §5 |
| `certificate-arn` | XPlatformCluster → `status.certificateArn` | `platform-cluster.yaml:501-503` |
| `external-dns-role-arn` | XSpokeAccess → `status.externalDnsRoleArn` | `xspokeaccess.yaml:200-202` |
| `region` | **no surfaced source today** — PR-2 must add it (key in the `cluster-network` EnvironmentConfig from the terraform region var, surfaced to XR status) | review finding; `crossplane-phase3.tf:167-188` lacks it |

**Explicitly out of contract:** keycloak's `externalDatabase.host`/`port`
(`platform-services/keycloak/values.yaml:62-63`). They are database connection
data from a third XR (XDatabase `status.endpoint`/`status.port`), not cluster
facts. They travel the **keycloak-db connection-Secret path** (OI-2026-06-07-5 /
ADR-0005 ESO): the ExternalSecret that materializes `keycloak-db` on the spoke
templates `host`/`port` keys in, and the chart consumes them via its
`externalDatabase.existingSecret*` keys. *Implementation must verify the pinned
Bitnami chart (21.4.4) supports existingSecret host/port keys; fallback if not:
add the two keys to this contract and record the extension here.*

## Decision

**Carrier:** the per-cluster facts ride that cluster's ArgoCD **cluster Secret**
as the labels/annotations above, plus selector labels
`k8-platform.io/cluster-role: spoke` and `k8-platform.io/short-name: <prefix>`
(`spoke`, `workload1`). ArgoCD's native per-cluster object; one fact bus per
cluster; nothing per-app, nothing hand-overlaid; auto-008 §5 already put
`certArn`/`subdomain`/`domain` annotations in this design.

**Consumers:** per-add-on **ApplicationSets** (one per add-on, each generating
one Application per matching cluster Secret), `goTemplate: true` with
`goTemplateOptions: ["missingkey=error"]` (a missing contract key fails loudly at
generation, never renders an empty value). Selector scoping encodes which add-ons
belong on which clusters:

| ApplicationSet | Generator selector | Generates (today's names preserved) |
|---|---|---|
| ingress-nginx, external-dns, hello | `cluster-role: spoke` (all spokes) | `spoke-…` + `workload1-…` — the workload1-* mirror files collapse here; the phase-6 refactor arrives as a by-product |
| keycloak, kube-prometheus-stack, loki | `cluster-role: spoke` + `short-name: spoke` (platform spoke only) | `spoke-…` |
| alloy (hub agent) | `cluster-role: spoke` + `short-name: spoke` — selects the SPOKE Secret for `domain`, but the template **hard-codes** `destination.server: https://kubernetes.default.svc` and `project: hub-addons` | `hub-observability-alloy` |

Template discipline (enforced by a unit lint, both directions):
- `metadata.name: '{{index .metadata.labels "k8-platform.io/short-name"}}-<addon>'`;
  `spec.destination.name: '{{.name}}'` (the Secret name, e.g. `platform-spoke`) —
  two different identifiers, both templated; alloy's destination is the hard-coded
  exception above.
- Each template pins `project` to today's per-app value (`platform-spoke` /
  `hub-addons`) — AppProject scoping is unchanged and generated apps stay inside
  the existing destination whitelists.
- Sync-wave annotations are **copied onto the generated Applications'**
  `metadata.annotations` (waves order child apps inside bootstrap's reconcile
  only if they ride the generated objects).
- Per-cluster values files switch on short-name where they exist today
  (external-dns: `$values/platform-services/external-dns/{{short-name}}-values.yaml`;
  the current `values.yaml` is renamed `spoke-values.yaml`); the disjoint
  txt-owner/domainFilter identity stays in those committed files, not in the
  contract.
- ApplicationSets set `syncPolicy.preserveResourcesOnDeletion: true`: a deleted
  or relabeled cluster Secret must not cascade-delete live spoke workloads.
- Workloads stay cloud-agnostic: `hello` receives `domain`+`subdomain` only — no
  ARNs, no region.

**Why the generator is now safe (reversing auto-008 F1):** the hazard was an
accidental hub destination from generator output. Here every template pins
`project` explicitly, the `platform-spoke` AppProject still forbids the hub
server (`platform-spoke.yaml:56-61`), destination comes from `{{.name}}` of a
secret that only the registration path labels, and `missingkey=error` turns
template/contract drift into a loud generation failure. The one deliberate hub
destination (alloy) is pinned in a dedicated ApplicationSet under `hub-addons`,
which permits only the hub.

**Producer phasing:**
- **PR-1 (this change, static-only):** the ApplicationSets + contract + tests +
  schema tooling. Touches `argocd/**` and `tests/**` only. Inert before
  registration exactly as the per-app files were: an empty generator produces
  zero Applications and no sync error.
- **PR-2 (seam #5, the build-session change):** the durable registration Secret
  produced from committed source, carrying the contract labels/annotations, plus
  the `region` EnvironmentConfig/status addition. **Honest status:** the producer
  is an OPEN blocker (SUBSTRATE row 5, "hand-bootstrapped live again in
  auto-016"), and the record holds an unresolved mechanism fork — ADR-0005 chose
  ESO `target.template` for the caData-in-JSON assembly, while the
  OI-2026-06-07-1 entry's later paragraph recommends a provider-kubernetes
  `Object` (the hub `InjectedIdentity` ProviderConfig exists for exactly that,
  `crossplane-phase3.tf:228-269`). PR-2 must resolve that fork; the fact contract
  is mechanism-neutral (both writers can stamp metadata). ESO's
  `target.template.metadata.{labels,annotations}` fields are schema-verified;
  whether template values interpolate remote data is confirmed against live ESO
  docs at PR-2 time.

**Cutover (honest, non-atomic):** deleting the ten Application files while adding
the ApplicationSets means bootstrap **prunes** the old Application objects and
the ApplicationSet controller creates same-named **new** objects that re-sync
from scratch — a real delete-then-recreate window for the spoke add-ons on any
live environment. Accepted because the validation path for this whole seam is a
**teardown + rebuild from committed source** (SUBSTRATE order of operations);
there is no live environment whose continuity we are promising. On a
hypothetically live hub, this transition is an outage window and would be
sequenced deliberately.

## Alternatives considered

- **Literal per-cluster ConfigMap read by add-ons** (ADR-0005's corollary, now
  superseded): tree-grounded feasibility failure — two of the five facts land in
  chart-rendered **annotations** (cert ARN on the NLB Service, role ARN on the
  external-dns ServiceAccount) which cannot read ConfigMaps at runtime; serving
  them would force a mutating webhook into a deliberately audit-only Kyverno
  posture (or AWS LBC cert discovery, which covers ALB/Ingress, not NLB
  Services). The principle ADR-0005 encoded — cluster abstraction owns the facts,
  no per-app hand overlays, cloud-agnostic workloads — is fully preserved.
- **bootstrap `ignoreDifferences` on helm value fields**: keeps the banned
  pattern — values still need a live hand actor every bring-up; nothing converges
  from source. Rejected.
- **ApplicationSet plugin generator reading a ConfigMap**: requires deploying and
  operating a plugin sidecar; strictly heavier than the built-in cluster
  generator for the same data. Rejected.
- **Keep plain Applications**: Applications have no templating mechanism;
  rejected on fact.

## Consequences

- The selfHeal fight disappears structurally **post-cutover**: everything ArgoCD
  manages is in git; everything account-specific lives on the in-cluster Secret
  no git controller reverts; bootstrap is never paused *in steady state* (the
  cutover itself is non-atomic, above).
- The cluster Secret becomes ArgoCD's connection credential **and** the
  platform's fact bus — one object, one writer. Named coupling (from the security
  review): (a) anything that can write annotations on that Secret can redirect
  every add-on's cert/role/domain — PR-2 must name the **single writer of
  record** and the RBAC that restricts `argocd`-namespace Secret writes to it;
  (b) if ESO owns the Secret, a template bug now risks clobbering the connection
  `config` ArgoCD needs, not just staling a fact — PR-2's review must cover
  partial-write behavior.
- Version alignment: the deployed argo-cd chart is **6.7.3 (ArgoCD ~v2.10.x,
  ApplicationSet controller bundled and enabled)**; the kubeconform CRD store was
  pinned to argo-cd v2.13.1 — a pre-existing skew. This PR aligns
  `scripts/fetch-crds-for-kubeconform.sh` to the deployed minor and adds
  `applicationset-crd.yaml` to the fetch set, committing
  `applicationset_v1alpha1.json` so kubeconform actually validates the new kind
  (without the schema, `--ignore-missing-schemas` silently skips — a passing test
  that validates nothing).
- `bootstrap.yaml`'s `SyncWaves=true` syncOption is a fiction (no such ArgoCD
  option; waves are always-on) — corrected in this PR so the wave story rests on
  the annotation propagation above, not on a non-existent toggle.
- Test estate: `test_spoke_apps.sh`, `test_observability_apps.sh`,
  `test_keycloak_apps.sh`, `test_workload1_apps.sh` are rewritten for the
  ApplicationSet shape (`.spec.template.spec.*` paths; workload1 coverage moves
  from per-file to generated-per-cluster assertions); a new contract lint checks
  ApplicationSets reference only contract keys, pin projects, carry sync-waves,
  set `missingkey=error` + `preserveResourcesOnDeletion`, and pin
  `targetRevision` (the existing revision-pin test globs only `argocd/apps/*.yaml`
  non-recursively and skips non-Application kinds, so AppSets need their own
  check). `test_spoke_values_no_ephemeral.sh` is unchanged and still gates
  literals.

## Verification

Static (PR-1): kubeconform incl. the new ApplicationSet schema; the rewritten
app tests; the contract lint; no `OVERLAID-AT-REGISTRATION` markers remain under
`argocd/apps/spoke/`. Live (PR-2 + build session): clean bring-up from committed
source → registration Secret carries the contract → generated apps converge →
`hello.platform.<domain>` 200 via the PR #210 hard check → SUBSTRATE-READINESS
rows 4+5 evidence columns filled by run ID.
