# ADR-0010 PR-2 — producer design brief (the durable spoke registration Secret)

Scope: OI-2026-06-07-1 / SUBSTRATE-READINESS row 5. The four decisions ADR-0010
explicitly deferred to PR-2, each resolved here with tree/docs grounding, plus
the mechanism design. The accepted resolutions are recorded in ADR-0010
("PR-2 resolutions" section); this brief is the working paper.

---

## Decision 1 — the writer mechanism: ESO `target.template` vs provider-kubernetes `Object`

**Resolved: provider-kubernetes `Object` (namespaced, `kubernetes.m.crossplane.io/v1alpha1`)
composed by the `xspokeaccess-aws` Composition, via the hub `InjectedIdentity`
ProviderConfig.**

The record held a fork: ADR-0005 chose "plain ESO" (`PushSecret` → ASM →
`ExternalSecret` with `target.template` assembling caData-in-JSON); the
OI-2026-06-07-1 entry's later paragraph recommends a provider-kubernetes
`Object` assembled by Composition combines. ADR-0010 told PR-2 to verify the
ESO capability question against live docs before committing either way.

**Capability verification (live ESO docs, v0.9.13 — the pinned `eso_version`
in `terraform/management/variables.tf`):** ESO *can* write templated output to
secret metadata: `spec.target.template.templateFrom[].target` accepts
`Annotations` and `Labels`, interpolating remote secret data
(external-secrets.io/v0.9.13/guides/templating). So the fork is **not** decided
by capability — ESO could stamp the fact annotations. It is decided by data
flow:

| Criterion | ESO path | provider-kubernetes path |
|---|---|---|
| Where the five facts live | 2 XR statuses (`XPlatformCluster.status.certificateArn`, `XSpokeAccess.status.externalDnsRoleArn`) + EnvironmentConfig (`domain`) + XR specs (`subdomain`, `region`) — all **hub-local** | same |
| What ESO can template from | **remote provider data only** (ASM) — every fact must first be *pushed* to ASM | reads hub-local data directly via Composition patches |
| Producers needed | EKS Cluster MR connection secret (today `writeConnectionSecretToRef` is empty — OI-1) + `PushSecret`(s) + ASM secret(s) + the `ExternalSecret`; facts not in any connection secret (role ARN, cert ARN) need Composition `connectionDetails` additions to even reach a pushable Secret | one Observe `Object` + one writer `Object` + RBAC + one terraform edit (the hub ProviderConfig is replaced by the `.m.` ClusterProviderConfig, below) |
| New cloud surface | a second copy of the spoke's connection credential parked in ASM (cost + IAM surface + lifecycle) | none — data never leaves the hub |
| Writer-of-record story (ADR-0010 consequence (a)) | split: ESO controller writes the Secret, but N PushSecrets own the data | one writer: the Composition's `Object` |
| Partial-write risk (consequence (b)) | ESO refresh loop re-templates over a live Secret; a template bug clobbers the connection `config` | SSA apply of a manifest assembled *before* any write; completeness-gated (Decision 4) |
| Prior plumbing | none of the ESO chain exists for this path | the hub `InjectedIdentity` ProviderConfig was provisioned **for exactly this** (`crossplane-phase3.tf:211-269`: "the XSpokeAccess delivery path needs to write the ArgoCD spoke cluster Secret") |

**This explicitly amends ADR-0005** (round-2 review finding 1): ADR-0005's
Alternatives section did not merely scope ESO to secret movement — it rejected
provider-kubernetes for THIS Secret by name, on the ground that "it cannot
assemble the caData-in-JSON `config` (references copy a value to a field path,
no string templating)". That premise does not hold for the mechanism chosen
here: the JSON is assembled by the **Composition's `CombineFromComposite`**
before the Object ever sees it — provider-kubernetes only applies a finished
manifest (the OI-1 entry's own durability analysis already made this point).
So PR-2 reverses ADR-0005's Alternatives rejection *for the registration
Secret only*, records the amendment in ADR-0010's PR-2 section and in a
pointer inside ADR-0005, and updates the OI-2026-06-07-1 bolded Resolution.
ADR-0005's positive ESO decisions (PushSecret/ExternalSecret for secret
*movement*, e.g. keycloak-db = OI-2026-06-07-5; XPlatformSecret for
AWS-grade) stand.

**The honest minimal ESO shape** (round-2 review finding 2 — argued against
fairly, not a strawman): export the facts via Composition `connectionDetails`
into XR connection secrets, then PushSecret → ASM → one templated
ExternalSecret. Even minimal, that is ≥2 PushSecrets + ≥2 ASM secrets (the
five facts span TWO XRs — `externalDnsRoleArn` is XSpokeAccess status and can
never ride the cluster XR's connection secret; the non-secret facts
domain/subdomain/region must also ride a connection secret or be uncommittable
template literals), an AWS-billing/IAM surface holding a second copy of the
spoke connection credential, and two extra controllers in the convergence
loop — all to move data that never needs to leave the hub. (Also of record:
`platform-cluster.yaml`'s header narrates a `connectionDetails` block that
does not exist in the tree — the XR connection-secret path is itself
unbuilt, for both sides of this comparison.)

**Schema verification (live provider-kubernetes v1.2.1 CRDs — the pinned
`crossplane_provider_kubernetes_version`):**
- namespaced `Object` exists at `kubernetes.m.crossplane.io/v1alpha1`
  (scope: Namespaced) — composable by the namespaced v2 XSpokeAccess XR, with
  standard `managementPolicies` (`Observe`, `Create`, `Update`, `Delete`,
  `LateInitialize`, `*`) and `status.atProvider.manifest` (the observed remote
  object).
- `providerConfigRef` defaults to `{kind: ClusterProviderConfig}`;
  `ClusterProviderConfig` exists at `kubernetes.m.crossplane.io/v1alpha1`
  (cluster-scoped) with `credentials.source: InjectedIdentity` valid.
- ⚠️ The existing hub ProviderConfig (`crossplane-phase3.tf:253-264`) is the
  **legacy cluster-scoped `kubernetes.crossplane.io/v1alpha1 ProviderConfig`**
  — a different group, not referenceable by the namespaced Object. PR-2
  replaces it with a `kubernetes.m.crossplane.io/v1alpha1 ClusterProviderConfig`
  named `hub` (same `InjectedIdentity` credentials).

## Decision 2 — the `region` source

**Resolved: `XSpokeAccess.spec.region`** patches the
`k8-platform.io/region` annotation. Grounds:
- region is a **per-cluster** fact (the contract is per-Secret complete;
  ADR-0010); the `cluster-network` EnvironmentConfig is an **account-singleton**
  — putting region there bakes in "all clusters share one region", a constraint
  nothing else imposes (`XPlatformCluster.spec.region` is already per-cluster).
- `spec.region` already exists on the XSpokeAccess XRD (validated
  `^[a-z]{2}-[a-z]+-[0-9]$`, defaulted `us-east-1`, already patched into the
  AccessEntry/AccessPolicyAssociation MRs) — no new surface, no terraform
  change, committed-stable (not account-ephemeral).
- Authority to amend: the ADR's fact-table region row is itself marked
  "**no surfaced source today** — PR-2 must add it" (a deferral, ADR-0010
  fact table, row 5); PR-2 resolves it with the per-cluster source and amends
  the Producer cell accordingly.

## Decision 3 — Keycloak DB host/port

**Resolved: option (i), `extraEnvVarsSecret`.** The contract stays five facts.
Grounds:
- `platform-services/keycloak/values.yaml` (pinned Bitnami chart 21.4.4, gated
  by `test_keycloak_db_secret_contract.sh`) has **no existingSecret host/port
  keys** — chart values cannot carry them from a Secret.
- host/port are **XDatabase facts** (`status.endpoint`/`status.port`), not
  cluster facts. Extending the contract would (a) put a third XR's data on the
  cluster Secret, requiring either a second writer (violating Decision 4's
  single-writer rule) or coupling XSpokeAccess to XDatabase; (b) break the
  per-Secret-complete property for workload spokes that have no database.
- The Bitnami container honors `KEYCLOAK_DATABASE_HOST`/`KEYCLOAK_DATABASE_PORT`
  env vars; `extraEnvVarsSecret` injects them from the same ESO-materialized
  spoke Secret that already must exist for the DB password (the
  OI-2026-06-07-5 `PushSecret`→ASM→`ExternalSecret` path — genuinely *secret
  movement*, so ESO per ADR-0005). The spoke `ExternalSecret` adds two
  templated keys; the keycloak ApplicationSet sets
  `extraEnvVarsSecret: <that secret>`.
- **What is decided now vs later (round-2 review finding 6):** the firm PR-2
  decision is the *negative* one — host/port do NOT enter the cluster-facts
  contract (altitude + per-Secret-completeness grounds above); the contract
  closes at five keys. The *mechanism* (`extraEnvVarsSecret`) is the chosen
  direction but carries an unverified premise — duplicate env names
  (chart-rendered `KEYCLOAK_DATABASE_HOST` from `externalDatabase.host` vs the
  `extraEnvVarsSecret` entry) resolve last-wins in the container spec, which
  must be proven by a helm-render fixture when OI-2026-06-07-5 implements it.
  Labeled hypothesis-until-rendered; implementation rides OI-2026-06-07-5,
  not PR-2.

## Decision 4 — single writer of record + partial-write prevention

**Writer of record: the `spoke-cluster-secret` Object rendered by the
`xspokeaccess-aws` Composition**, executing as the provider-kubernetes pod SA
(pinned name `provider-kubernetes` via DeploymentRuntimeConfig) under the hub
`InjectedIdentity` ClusterProviderConfig.

- **Honest framing (round-2 review finding 4): these are convergence and
  process controls, not a security boundary.** ArgoCD's own controllers
  inherently write `argocd`-namespace Secrets; ESO is installed cluster-wide
  and an ExternalSecret targeting `argocd` is not blocked; every Kyverno
  policy is `Audit`. "Single writer of record" means: among the
  *platform-authored* mechanisms, exactly one (this Object) creates/updates
  registration Secrets, the REST/kubectl bootstrap path is retired from the
  runbooks, and RBAC grants the new capability to exactly one pinned SA —
  nothing else is widened. An admission-enforced fence would require an
  Enforce-mode policy, which the deliberately audit-only Kyverno posture
  rules out (same trade ADR-0010 recorded for the consumer half).
- **RBAC:** a namespaced `Role` in `argocd` grants the pinned SA secret write
  verbs; a `Role` in `platform` grants it read on `xplatformclusters` (for the
  Observe Object). The ESO ClusterRole precedent (`crossplane/rbac/01-…`)
  pattern is followed; the grant is namespace-scoped, not cluster-wide.
- **Partial-write prevention: the Secret is complete-or-absent.** Every patch
  sourcing a late-arriving fact (`clusterEndpoint` → `server`, the
  `clusterName`+`clusterCaData` → `config` combine, the `certificate-arn` and
  `external-dns-role-arn` annotations) carries
  `policy.fromFieldPath: Required`. Verified against the pinned
  function-patch-and-transform v0.10.6 source (round-2 mechanics review,
  finding 1): a Required patch that cannot resolve **skips creating that one
  composed resource** (emitting a function Warning) and leaves every sibling
  resource untouched — it does *not* fail the pipeline. So the Object — and
  therefore the Secret, `argocd.argoproj.io/secret-type: cluster` label and
  all — is not created until every fact resolves, and the first write is one
  complete SSA apply. (An earlier draft gated the secret-type label via a
  `%.0s` combine canary; Required-gated creation gives the same
  complete-or-absent guarantee with stock semantics and no fmt tricks.) The
  contract lint asserts every late-fact patch on the Secret Object carries
  the Required policy.
- **Fact regression, named (mechanics review 10e):** if an already-resolved
  fact later clears (a cluster XR status field regresses), the Required
  policy is ignored for an *existing* resource — the patch skips, the field
  leaves the desired manifest, and SSA removes it from the live Secret. The
  failure is loud, not silent: a removed annotation trips the consumers'
  `missingkey=error` at generation; a removed `config`/`server` fails the
  ArgoCD connection. `preserveResourcesOnDeletion: true` on the consumers
  keeps live workloads intact throughout (ADR-0010). XR statuses do not
  normally un-populate; this is a documented residual, not a designed state.

## Mechanism (how the facts reach the writer)

The five facts span two XRs. The cluster-side facts cross XR boundaries via an
**Observe-only `Object`** (`managementPolicies: [Observe]`) on the
`XPlatformCluster` XR — the established "cross-resource refs travel via the
composite" idiom, extended one hop:

```
XPlatformCluster.status ──(Observe Object: status.atProvider.manifest)──▶
  XSpokeAccess.status.{clusterOidcIssuer,clusterEndpoint,clusterCaData,clusterCertificateArn}
    ──(FromComposite / combines)──▶ spoke-cluster-secret Object manifest
XSpokeAccess own MRs: status.externalDnsRoleArn ──▶ annotation
EnvironmentConfig: domain ──▶ annotation;  XR spec: subdomain, region, shortName
```

- `XPlatformCluster` XRD/Composition gain `status.clusterCaData` (←
  `status.atProvider.certificateAuthority[0].data`, base64 PEM — public cert
  material, safe on status; endpoint/oidcIssuer/certificateArn are already
  published).
- `XSpokeAccess` XRD gains `spec.shortName` (the ADR-0010 selector label
  value, e.g. `spoke`) and the four `cluster*` status mirrors. The Observe
  Object targets the `XPlatformCluster` with the XSpokeAccess XR's **own
  `metadata.name` and namespace** — no free-text target field to typo (round-2
  review finding 4): a broken pairing is observe-not-found = `Synced=False`,
  loud, never a wrong-cluster read. The 1:1 name pairing is asserted by a unit
  lint across `clusters/**`. Residual risk, named: in a multi-spoke future,
  deliberately mis-pairing two *registered* spokes would read the wrong
  cluster's facts; the fail-closed property below bounds it for clusters the
  argocd role has no AccessEntry on, and the pairing lint guards the committed
  tree.
- **Loudness guard (round-2 review finding 5):** the Observe Object carries a
  `readinessChecks: NonEmpty` on the latest-arriving observed fact
  (`status.atProvider.manifest.status.clusterCaData`), so "target exists but
  facts never populate" (RBAC gap, cluster never Ready) holds the Object —
  and therefore the XR — visibly `Ready=False` with the readiness reason,
  instead of an invisible unlabeled Secret. RBAC-denied reads are
  `Synced=False` on the Object. Neither state is silent.
- **`spec.oidcIssuer` is removed — this reverses the auto-008 C2 input
  design** (stated per the ADR-0010 reversal-labeling standard): the issuer
  now arrives from the Observe Object (`status.clusterOidcIssuer`) instead of
  an operator overlay, deleting the last placeholder-overlay manual step from
  the spoke bring-up (`SUBSTRATE-READINESS.md` bans exactly that overlay). C2's
  *ordering* concern is still honored by the manual-sync gate (sync after
  cluster Ready) plus the readiness guard above; the strict schema makes any
  old-runbook overlay fail loudly at admission. Before facts populate, fact
  patches skip (Optional) and the affected MRs retry; with the readiness
  guard, the wait-state is visible on the XR.
- Secret shape (matches the live registration that worked in auto-012, the
  ADR-0010 consumer templates, AND the `platform-spoke` AppProject destination
  allowlist `platform-spoke`/`*-spoke` — round-2 review finding 3):
  `metadata.name` = `stringData.name` = **`<spec.subdomain>-spoke`**
  (`platform-spoke`, `workload1-spoke`); `stringData.server` = cluster
  endpoint; `stringData.config` =
  `{"awsAuthConfig":{"clusterName":"<spec.clusterName>"},"tlsClientConfig":{"caData":"<base64>"}}`
  — clusterName stays `spec.clusterName` (the same value the AccessEntry
  grants on), so a wrong-cluster fact read cannot authenticate: the hub argocd
  role has no AccessEntry on a cluster whose XSpokeAccess didn't grant it —
  **fail-closed at auth**; labels `k8-platform.io/cluster-role: spoke`,
  `k8-platform.io/short-name`; annotations = exactly the five contract keys.

## Test layers shipping with PR-2

- `test_cluster_facts_contract.sh` gains the producer half: the Composition
  emits exactly the contract annotation/label keys (bidirectional), every
  late-fact patch on the Secret Object carries `policy.fromFieldPath:
  Required`, and the Secret/registration name follows `<subdomain>-spoke`
  (the AppProject allowlist contract).
- `test_xspokeaccess.sh` rewritten for the new shape (7 resources, Object
  assertions, RBAC files, XR↔cluster-XR name-pairing lint, no oidcIssuer).
- Render fixtures: xspokeaccess `input.yaml` carries a populated status block
  (probe values) so the golden renders the *complete* Secret — a brand-new
  golden path (no prior input fixture carries status), bootstrapped fresh.
- New chainsaw `xspokeaccess/00-xrd-establishes` (XRD admission contract — the
  XRD is a v2 CRD-boundary change, ADR-0001), dispatched per the heavy-CI
  protocol. Harness fit verified (mechanics review, finding 9): the dry-run
  shape needs no extra providers; `test_chainsaw_golden_files_present.sh`
  gets the `xspokeaccess/00-xrd-establishes` exemption (same class as the
  two existing XRD-establishes exemptions); the canonical catch block is
  pasted verbatim with `describe.kind: XSpokeAccess` (its xr_kind diagnostic
  loop does not enumerate xspokeaccess — accepted, noted in the scenario
  header, since appending to the canonical list would force editing every
  existing scenario's catch block in the same PR).
- Live (clean build, later session): registration Secret appears labeled with
  the full contract → generated apps converge → hello 200 (PR #210 check).
