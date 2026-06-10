# 0010 — Cluster facts reach spoke Applications via cluster-Secret annotations templated by ApplicationSets

- **Status**: Accepted (owner-ratified 2026-06-10 after round-1 adversarial
  review — 2 reviewers, 5 BLOCKER + 7 MAJOR findings folded in; reviews in
  `planning/adr-0010-cluster-facts/`)
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
| `region` | `XSpokeAccess.spec.region` (PR-2 resolution — region is per-cluster, not account-global; the EnvironmentConfig sketch below was the deferral placeholder) | PR-2 §Decision 2; `xspokeaccess.yaml` spec.region (validated, defaulted) |

**Explicitly out of contract:** keycloak's `externalDatabase.host`/`port`
(`platform-services/keycloak/values.yaml:62-63`). They are database connection
data from a third XR (XDatabase `status.endpoint`/`status.port`), not cluster
facts. **Repo-verified constraint** (`platform-services/keycloak/values.yaml`
header, pinned by `test_keycloak_db_secret_contract.sh`): the pinned Bitnami
chart (21.4.4) has NO existingSecret host/port keys — they cannot ride the
connection Secret via chart values. They are therefore the one remaining
ephemeral-value gap after PR-1, resolved in PR-2 by either (i)
`extraEnvVarsSecret` overriding `KEYCLOAK_DATABASE_HOST`/`PORT` from an
ESO-materialized secret, or (ii) extending this contract with the two keys —
PR-2 decides and records which here.

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
  produced from committed source, carrying the contract labels/annotations.
  **Resolved 2026-06-10 — see "PR-2 resolutions" below.** (Original deferral:
  the producer was an OPEN blocker with an unresolved
  ESO-vs-provider-kubernetes mechanism fork. PR-2 resolved it for
  provider-kubernetes after verifying against live ESO docs that ESO *could*
  interpolate annotations from remote data — `templateFrom` with
  `target: Annotations` exists in the pinned v0.9.13 — so the fork was
  decided on data-flow architecture, not capability.)

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

## PR-2 resolutions (2026-06-10 — the producer; OI-2026-06-07-1)

Working paper with full grounding + two adversarial review rounds:
`planning/adr-0010-cluster-facts/adr0010-pr2-producer-brief.md`. Status of
everything below: **pending clean-build verification** (SUBSTRATE row 5).

1. **Writer mechanism — provider-kubernetes `Object`, not ESO.** The
   registration Secret is written by a `spoke-cluster-secret` Object
   (namespaced `kubernetes.m.crossplane.io/v1alpha1`, verified in the pinned
   provider v1.2.1) composed by `xspokeaccess-aws`, via the hub
   `InjectedIdentity` ClusterProviderConfig. Capability was NOT the decider:
   live ESO v0.9.13 docs confirm `templateFrom`/`target: Annotations` can
   stamp remote data into metadata. Data flow was: the five facts span two XR
   statuses + the EnvironmentConfig, all hub-local; ESO can only template
   *remote provider* data, so even the minimal ESO shape round-trips ≥2
   connection-detail Secrets through AWS Secrets Manager (a second cloud copy
   of the spoke credential) to move data that never needs to leave the hub.
   **This amends ADR-0005's Alternatives rejection of provider-kubernetes for
   OI-1**: that rejection assumed the JSON assembly had to happen in
   provider-kubernetes references; it happens in the Composition's
   `CombineFromComposite` — the Object only applies a finished manifest.
   ADR-0005's positive ESO decisions (secret *movement*; XPlatformSecret for
   AWS-grade) stand. Cluster-side facts cross the XR boundary via an
   Observe-only Object on the **paired** XPlatformCluster (the XSpokeAccess
   XR's own name/namespace — no free-text target; readiness requires all four
   observed facts so a stuck producer is loudly Ready=False). This also
   retires the `spec.oidcIssuer` placeholder overlay (a SUBSTRATE-banned
   manual step), reversing the auto-008 C2 *input* design while keeping its
   ordering gate (manual-sync after cluster Ready).
2. **`region` source — `XSpokeAccess.spec.region`** (amends the fact table
   above, per its own deferral note). Region is a per-cluster fact; the
   account-singleton EnvironmentConfig is the wrong altitude, and the field
   already exists validated + defaulted on the XRD.
3. **Keycloak DB host/port — NOT contract keys (firm); `extraEnvVarsSecret`
   (direction).** host/port are XDatabase facts; putting them on the cluster
   Secret would need a second writer or an XSpokeAccess→XDatabase coupling
   and break per-Secret completeness for DB-less spokes. The chosen
   mechanism: the OI-2026-06-07-5 ESO-materialized spoke secret adds
   `KEYCLOAK_DATABASE_HOST`/`PORT` keys consumed via the chart's
   `extraEnvVarsSecret`. The duplicate-env-name precedence (chart-rendered
   env vs extraEnvVarsSecret) is an unverified premise — labeled hypothesis;
   OI-5's implementation must prove it with a helm-render fixture. The
   contract closes at five keys.
4. **Single writer / partial writes.** Writer of record = the
   `spoke-cluster-secret` Object under the pinned `provider-kubernetes` SA
   (DeploymentRuntimeConfig), RBAC-granted argocd-namespace Secret writes +
   platform-namespace XPlatformCluster reads
   (`crossplane/rbac/02-provider-kubernetes-spoke-cluster-secret.yaml`); the
   REST/kubectl registration path is retired from runbooks. **Honest
   framing: a convergence/process control, not a security boundary** —
   ArgoCD's controllers inherently write argocd-ns Secrets, ESO is
   cluster-wide, Kyverno is Audit-only. Partial writes are prevented by
   construction: every patch into the Secret manifest is
   `policy.fromFieldPath: Required`, which under the pinned p&t v0.10.6
   skips creating *this one* composed resource until every fact resolves —
   the Secret is complete-or-absent (gated by the contract lint). Named
   residual: a *regressing* fact on an existing Secret is removed by SSA and
   fails loudly downstream (`missingkey=error` / connection failure);
   `preserveResourcesOnDeletion` keeps workloads intact.

Registration naming: `<spec.subdomain>-spoke` (`platform-spoke`,
`workload1-spoke`) — required by the `platform-spoke` AppProject destination
allowlist (`platform-spoke` / `*-spoke`); gated by the contract lint.
