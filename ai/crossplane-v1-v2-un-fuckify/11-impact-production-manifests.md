# 11 — Impact trace: production K8s manifests

**Author:** sonnet impact-tracer
**Scope:** crossplane/, argocd/, clusters/, policies/, platform-services/ (production manifests only — not tests or terraform)

## Manifest impact matrix

| File | Kind | v2 breaks | Live-cluster effect |
|---|---|---|---|
| `crossplane/compositions/platform-secret.yaml` | Composition | API-GROUP, MR-DELETION-POLICY, MR-PROVIDER-CONFIG-REF, MR-CONNECTION-DETAILS-NS, XR-CLUSTER-SCOPED | ADMISSION-REJECT |
| `crossplane/compositions/platform-cluster.yaml` | Composition | API-GROUP, MR-DELETION-POLICY, MR-PROVIDER-CONFIG-REF, MR-CONNECTION-DETAILS-NS, XR-CLUSTER-SCOPED | ADMISSION-REJECT |
| `crossplane/xrds/platform-secret.yaml` | CompositeResourceDefinition | XRD-CLAIM, XR-CLUSTER-SCOPED | BLAST |
| `crossplane/xrds/platform-cluster.yaml` | CompositeResourceDefinition | XRD-CLAIM, XR-CLUSTER-SCOPED | BLAST |
| `crossplane/xrds/platform-secret/render-fixtures/input.yaml` | XPlatformSecret (XR fixture) | XR-CLUSTER-SCOPED | RUNTIME-FAIL |
| `crossplane/xrds/platform-cluster/render-fixtures/input.yaml` | XPlatformCluster (XR fixture) | XR-CLUSTER-SCOPED | RUNTIME-FAIL |
| `crossplane/claims/example-platform-secret.yaml` | PlatformSecret | XR-CLUSTER-SCOPED | RUNTIME-FAIL |
| `crossplane/claims/example-platform-cluster.yaml` | PlatformCluster | XR-CLUSTER-SCOPED | RUNTIME-FAIL |
| `crossplane/rbac/01-crossplane-externalsecrets.yaml` | ClusterRole, ClusterRoleBinding | — | OK-NOOP |
| `crossplane/policies/09-platform-secret-namespace-allowed.yaml` | ClusterPolicy | — | OK-NOOP |
| `argocd/apps/crossplane-resources.yaml` | Application | ARGOCD-APP-REVISION | RUNTIME-FAIL |
| `argocd/apps/management-cluster-config.yaml` | Application | — | OK-NOOP |
| `argocd/apps/platform-cluster-claim.yaml` | Application | ARGOCD-APP-REVISION | RUNTIME-FAIL |
| `argocd/bootstrap.yaml` | Application | — | OK-NOOP |
| `argocd/projects/k8-platform.yaml` | AppProject | — | OK-NOOP |
| `clusters/management/eso/cluster-secret-store.yaml` | ClusterSecretStore | — | OK-NOOP |
| `clusters/platform/platform-cluster-claim.yaml` | PlatformCluster | XR-CLUSTER-SCOPED | RUNTIME-FAIL |
| `policies/audit/01-argocd-server-irsa.yaml` | ClusterPolicy | — | OK-NOOP |
| `policies/audit/02-ingress-must-have-class.yaml` | ClusterPolicy | — | OK-NOOP |
| `policies/audit/03-ingress-managed-by-external-dns.yaml` | ClusterPolicy | — | OK-NOOP |
| `policies/audit/04-irsa-rolearn-format.yaml` | ClusterPolicy | — | OK-NOOP |
| `policies/audit/05-no-default-sa-with-workload.yaml` | ClusterPolicy | — | OK-NOOP |
| `policies/audit/06-image-tag-not-latest.yaml` | ClusterPolicy | — | OK-NOOP |
| `policies/audit/07-helm-release-labels-required.yaml` | ClusterPolicy | — | OK-NOOP |
| `policies/audit/08-external-dns-annotation-on-services.yaml` | ClusterPolicy | — | OK-NOOP |
| `platform-services/**` | (empty — only .gitkeep files) | — | OK-NOOP |

---

## Per-file detail (only files with at least one break)

### crossplane/compositions/platform-secret.yaml

**Breaks:** API-GROUP, MR-DELETION-POLICY, MR-PROVIDER-CONFIG-REF, MR-CONNECTION-DETAILS-NS, XR-CLUSTER-SCOPED

- **L37: `writeConnectionSecretsToNamespace: crossplane-system`** — `MR-CONNECTION-DETAILS-NS`. This field on a Composition is a v1 pattern directing where XR connection secrets land. In v2 the connection-secret model changes (XRs are namespaced; connection secrets land in the XR's namespace). The field is not part of the v2 Composition schema and will be rejected or silently ignored.
- **L51: `apiVersion: secretsmanager.aws.upbound.io/v1beta1`** — `API-GROUP`. The v1 API group `secretsmanager.aws.upbound.io` must become `secretsmanager.aws.m.upbound.io` (the `.m.` infix is mandatory in provider v2.5.4). The CRD under the old group will not exist once the provider is bumped.
- **L61: `deletionPolicy: Delete`** — `MR-DELETION-POLICY`. `deletionPolicy` is removed for namespaced MRs in v2. With strict decoding the field will be rejected on admission.
- **L62-63: `providerConfigRef:\n  name: default`** — `MR-PROVIDER-CONFIG-REF`. Missing `kind:` field. In v2 `providerConfigRef` requires an explicit `kind:` (`ClusterProviderConfig` or `ProviderConfig`). Without it the MR fails validation under v2's strict schema.
- **Composition `spec.compositeTypeRef` (L34-36) references a cluster-scoped XR (`XPlatformSecret`)** — `XR-CLUSTER-SCOPED`. Under v2 XRs are namespaced. If the XRD is migrated (claimNames removed, XR becomes namespaced) without updating the Composition's compositeTypeRef, or vice-versa, the Composition will not bind to any XR instances.

**Effect:** ADMISSION-REJECT under v2 strict decoding. The `secretsmanager.aws.upbound.io/v1beta1` CRD does not exist post-provider-bump; Crossplane's function-patch-and-transform will fail to resolve the base MR type. Additionally `deletionPolicy` and `providerConfigRef` (missing `kind`) will fail v2 schema validation. Every PlatformSecret claim is broken until this Composition is corrected.

---

### crossplane/compositions/platform-cluster.yaml

**Breaks:** API-GROUP (×5 resources), MR-DELETION-POLICY (×8 resources), MR-PROVIDER-CONFIG-REF (×8 resources), MR-CONNECTION-DETAILS-NS, XR-CLUSTER-SCOPED

- **L51: `writeConnectionSecretsToNamespace: crossplane-system`** — `MR-CONNECTION-DETAILS-NS`. Same v1 pattern as platform-secret Composition.
- **L65: `apiVersion: iam.aws.upbound.io/v1beta1`** (`cluster-role` resource) — `API-GROUP`. Needs `iam.aws.m.upbound.io`.
- **L84: `deletionPolicy: Delete`** (`cluster-role`) — `MR-DELETION-POLICY`.
- **L85-86: `providerConfigRef:\n  name: default`** (`cluster-role`) — `MR-PROVIDER-CONFIG-REF`.
- **L106: `apiVersion: iam.aws.upbound.io/v1beta1`** (`cluster-role-policy` resource) — `API-GROUP`.
- **L111: `deletionPolicy: Delete`** (`cluster-role-policy`) — `MR-DELETION-POLICY`.
- **L112-113: `providerConfigRef:\n  name: default`** (`cluster-role-policy`) — `MR-PROVIDER-CONFIG-REF`.
- **L127: `apiVersion: iam.aws.upbound.io/v1beta1`** (`node-role` resource) — `API-GROUP`.
- **L146: `deletionPolicy: Delete`** (`node-role`) — `MR-DELETION-POLICY`.
- **L147-148: `providerConfigRef:\n  name: default`** (`node-role`) — `MR-PROVIDER-CONFIG-REF`.
- **L168: `apiVersion: iam.aws.upbound.io/v1beta1`** (`node-worker-policy` resource) — `API-GROUP`.
- **L173: `deletionPolicy: Delete`** (`node-worker-policy`) — `MR-DELETION-POLICY`.
- **L174-175: `providerConfigRef:\n  name: default`** (`node-worker-policy`) — `MR-PROVIDER-CONFIG-REF`.
- **L190: `apiVersion: iam.aws.upbound.io/v1beta1`** (`node-cni-policy` resource) — `API-GROUP`.
- **L195: `deletionPolicy: Delete`** (`node-cni-policy`) — `MR-DELETION-POLICY`.
- **L196-197: `providerConfigRef:\n  name: default`** (`node-cni-policy`) — `MR-PROVIDER-CONFIG-REF`.
- **L211: `apiVersion: iam.aws.upbound.io/v1beta1`** (`node-ecr-policy` resource) — `API-GROUP`.
- **L216: `deletionPolicy: Delete`** (`node-ecr-policy`) — `MR-DELETION-POLICY`.
- **L217-218: `providerConfigRef:\n  name: default`** (`node-ecr-policy`) — `MR-PROVIDER-CONFIG-REF`.
- **L231: `apiVersion: eks.aws.upbound.io/v1beta1`** (`eks-cluster` resource) — `API-GROUP`. Needs `eks.aws.m.upbound.io`.
- **L253: `deletionPolicy: Delete`** (`eks-cluster`) — `MR-DELETION-POLICY`.
- **L254-255: `providerConfigRef:\n  name: default`** (`eks-cluster`) — `MR-PROVIDER-CONFIG-REF`.
- **L289: `apiVersion: eks.aws.upbound.io/v1beta1`** (`eks-nodegroup` resource) — `API-GROUP`. Needs `eks.aws.m.upbound.io`.
- **L311: `deletionPolicy: Delete`** (`eks-nodegroup`) — `MR-DELETION-POLICY`.
- **L312-313: `providerConfigRef:\n  name: default`** (`eks-nodegroup`) — `MR-PROVIDER-CONFIG-REF`.
- **Composition `spec.compositeTypeRef` (L49-51) references cluster-scoped `XPlatformCluster`** — `XR-CLUSTER-SCOPED`. Same concern as platform-secret Composition.

**Summary of counts within this one file:** 5 distinct API-GROUP occurrences (iam×4, eks×2 type groups), 8 deletionPolicy, 8 providerConfigRef-missing-kind.

**Effect:** ADMISSION-REJECT. None of the 3 AWS provider API groups (`iam.aws.upbound.io`, `eks.aws.upbound.io`) exist post-provider-bump. All 8 MR templates fail. Every PlatformCluster claim is broken.

---

### crossplane/xrds/platform-secret.yaml

**Breaks:** XRD-CLAIM, XR-CLUSTER-SCOPED

- **L26-30: `claimNames:` block** — `XRD-CLAIM`. In Crossplane v2 the XR/Claim separation is removed. XRDs no longer support `claimNames:`. Under v2 the `claimNames` field is not in the `CompositeResourceDefinition` schema; strict decoding will reject this XRD on admission.

  ```yaml
  claimNames:
    kind: PlatformSecret
    plural: platformsecrets
    listKind: PlatformSecretList
    singular: platformsecret
  ```

- **No `scope:` field, implying cluster-scoped XR (v1 default)** — `XR-CLUSTER-SCOPED`. In v2, XRs are namespaced. The XRD must declare `spec.scope: Namespaced`. Without it, if the field is dropped during migration, existing `PlatformSecret` claim objects (which were CRD kinds generated from `claimNames`) will have no corresponding CRD after migration.

**Effect:** BLAST. Rejecting or changing this XRD breaks every PlatformSecret claim in every namespace. The `PlatformSecret` CRD (generated from `claimNames`) will cease to exist in v2 — any existing claim objects become orphaned stranded resources. All consumers must switch to creating `XPlatformSecret` XRs directly in their namespace.

---

### crossplane/xrds/platform-cluster.yaml

**Breaks:** XRD-CLAIM, XR-CLUSTER-SCOPED

- **L38-43: `claimNames:` block** — `XRD-CLAIM`. Same as platform-secret: must be removed for v2. The block:

  ```yaml
  claimNames:
    kind: PlatformCluster
    plural: platformclusters
    listKind: PlatformClusterList
    singular: platformcluster
  ```

- **No `scope:` field (cluster-scoped v1 default)** — `XR-CLUSTER-SCOPED`. Same as platform-secret XRD.

**Effect:** BLAST. The `PlatformCluster` CRD (claim kind) will cease to exist. `clusters/platform/platform-cluster-claim.yaml` and `crossplane/claims/example-platform-cluster.yaml` both use `kind: PlatformCluster` and will become orphaned. The ArgoCD Application `platform-cluster-claim` will error on sync because the target kind no longer has a CRD.

---

### crossplane/xrds/platform-secret/render-fixtures/input.yaml

**Breaks:** XR-CLUSTER-SCOPED

- This file defines an `XPlatformSecret` XR (not a claim) but includes `spec.claimRef:` (L20-27) which is a v1-era field. In v2 (no claim/XR separation) `claimRef` is removed from the XR spec. The Composition's ExternalSecret patches read `spec.claimRef.name` (Composition L122) and `spec.claimRef.namespace` (Composition L130) — these patches will produce empty values after migration since `claimRef` no longer exists on the XR spec.

**Effect:** RUNTIME-FAIL for `crossplane render` dry-run. Not a live-cluster manifest applied by ArgoCD, but it is under `crossplane/xrds/` which is in the ArgoCD `crossplane-resources` app's recurse path. If ArgoCD recurse picks it up, it will attempt to apply an `XPlatformSecret` object, which in v2 must be namespaced — this will fail admission if the cluster is in v2 mode and the XRD is migrated.

---

### crossplane/xrds/platform-cluster/render-fixtures/input.yaml

**Breaks:** XR-CLUSTER-SCOPED

- Defines an `XPlatformCluster` XR with `spec.claimRef:` (L15-19). Same concern as platform-secret render fixture. The `claimRef` field is v1-only.

**Effect:** RUNTIME-FAIL for same reasons as platform-secret render fixture above.

---

### crossplane/claims/example-platform-secret.yaml

**Breaks:** XR-CLUSTER-SCOPED

- **L11: `kind: PlatformSecret`** — this is a claim kind generated by the XRD's `claimNames:`. Once the XRD is migrated to v2 (claimNames removed), the `PlatformSecret` CRD ceases to exist. This file would target a non-existent CRD.
- Note: this file is explicitly excluded from ArgoCD sync (`claims/` dir is excluded per `crossplane-resources.yaml` L29). However it is a live example that operators apply by hand.

**Effect:** RUNTIME-FAIL — after XRD migration the kind `PlatformSecret` in `platform.k8-platform.io` API group will not exist. `kubectl apply` of this file will return "no matches for kind PlatformSecret in group platform.k8-platform.io".

---

### crossplane/claims/example-platform-cluster.yaml

**Breaks:** XR-CLUSTER-SCOPED

- **L22: `kind: PlatformCluster`** — same situation as example-platform-secret. The `PlatformCluster` CRD is generated from the XRD's `claimNames:` block and will not exist after v2 XRD migration.
- Comment on L18: `kubectl get platformcluster -A` will return no resources once the CRD is gone.

**Effect:** RUNTIME-FAIL — same as example-platform-secret above.

---

### argocd/apps/crossplane-resources.yaml

**Breaks:** ARGOCD-APP-REVISION

- **L28-29:** `path: crossplane` with `directory.recurse: true` and `include: '{xrds/*.yaml,compositions/*.yaml,policies/*.yaml,rbac/*.yaml}'`. This Application syncs the XRDs and Compositions that have v2 breaks. After the manifests are corrected, ArgoCD will diff against live cluster state (existing v1 XRD objects with `claimNames`, existing v1 Compositions) and apply the corrected versions. The `ServerSideApply=true` option means the corrected XRD will be applied via SSA — the live `claimNames` field will be removed, triggering CRD deletion of the `PlatformSecret` and `PlatformCluster` claim CRDs immediately. This is a destructive operation on live XRD state and cascades to all claim objects currently on the cluster.
- Additionally the `include` glob picks up `crossplane/xrds/platform-secret/render-fixtures/input.yaml` and `crossplane/xrds/platform-cluster/render-fixtures/input.yaml` because `recurse: true` descends into subdirs. These XR fixture files will be applied to the cluster as live objects (XPlatformSecret and XPlatformCluster instances), which was likely unintended.

**Effect:** RUNTIME-FAIL — the Application itself will sync; the break is that its source manifests (XRDs, Compositions) contain v2 breaks that will cause admission rejection or CRD deletion cascades. The ArgoCD sync will report `SyncFailed` for those resources.

---

### argocd/apps/platform-cluster-claim.yaml

**Breaks:** ARGOCD-APP-REVISION

- **L38-40:** `path: clusters/platform` with `include: 'platform-cluster-claim.yaml'`. This syncs `clusters/platform/platform-cluster-claim.yaml` which uses `kind: PlatformCluster`. After XRD migration the `PlatformCluster` CRD will not exist, so the Application will fail to sync with "no matches for kind PlatformCluster".

**Effect:** RUNTIME-FAIL — ArgoCD sync for `platform-cluster-claim` Application will fail after XRD migration removes the `PlatformCluster` CRD.

---

### clusters/platform/platform-cluster-claim.yaml

**Breaks:** XR-CLUSTER-SCOPED

- **L22: `kind: PlatformCluster`** — uses the claim kind that will be removed when the XRD is migrated to v2. After XRD migration the CRD no longer exists.
- This is an active live manifest synced by ArgoCD (`platform-cluster-claim` Application, wave 10).

**Effect:** RUNTIME-FAIL — after XRD migration the kind will be unknown to the API server. ArgoCD will report a sync error. Any currently-provisioned EKS cluster managed by this claim will have its claim object become an orphaned resource (no owning CRD), though the underlying Crossplane XR and AWS resources may persist depending on finalizer state.

---

## Cross-cutting observations

**Total files inspected:** 26 YAML files (25 distinct manifests + 1 platform-services dir with only .gitkeep — no YAML content)

**Count by verdict:**
- `BLAST`: 2 (both XRDs)
- `ADMISSION-REJECT`: 2 (both Compositions)
- `RUNTIME-FAIL`: 8 (4 claim/fixture files + 2 ArgoCD apps + 1 live cluster claim)
- `OK-NOOP`: 14 (RBAC, Kyverno policies, ESO ClusterSecretStore, ArgoCD bootstrap + project + management-cluster-config app)

**Count by break category:**
- `API-GROUP`: 2 files (platform-secret.yaml composition: 1 group; platform-cluster.yaml composition: 3 distinct AWS provider groups across 8 resource templates)
- `XRD-CLAIM`: 2 files (both XRDs)
- `MR-DELETION-POLICY`: 2 files (9 total occurrences: 1 in platform-secret, 8 in platform-cluster)
- `MR-PROVIDER-CONFIG-REF`: 2 files (9 total occurrences: 1 in platform-secret, 8 in platform-cluster)
- `MR-CONNECTION-DETAILS-NS`: 2 files (both Compositions via `writeConnectionSecretsToNamespace`)
- `XR-CLUSTER-SCOPED`: 8 files (both XRDs, both Compositions via compositeTypeRef, both render fixtures, both example claims, both cluster claim files)
- `KYVERNO-MATCH-PATTERN`: 0 files — all Kyverno policies in `policies/audit/` match on standard Kubernetes kinds (Ingress, Service, Pod, Deployment, ServiceAccount) or the custom kind `PlatformSecret` by short name only (no API group pinned). `crossplane/policies/09-platform-secret-namespace-allowed.yaml` matches on `kind: PlatformSecret` without an API group — this will break silently if the claim kind is removed in v2 (the match will never fire), but it is not a hard schema break.
- `ARGOCD-APP-REVISION`: 2 files (`crossplane-resources` and `platform-cluster-claim` Applications)

**ArgoCD Application paths that need attention because their source manifests are affected:**
- `argocd/apps/crossplane-resources.yaml` → syncs `crossplane/` (XRDs and Compositions, both broken). The `recurse: true` + `include` glob also inadvertently picks up render fixture files under `crossplane/xrds/*/render-fixtures/` — these will be applied to the cluster as live XR instances.
- `argocd/apps/platform-cluster-claim.yaml` → syncs `clusters/platform/platform-cluster-claim.yaml` which uses the claim kind `PlatformCluster` that will not exist after XRD migration.

**XRD changes that BLAST (break every consumer claim):**
- `crossplane/xrds/platform-secret.yaml`: removing `claimNames:` deletes the `PlatformSecret` CRD. Every `PlatformSecret` claim object in the cluster (in namespaces `platform`, `apps`, `default` per the Kyverno allowlist) becomes an orphaned resource. Consumers must replace claim objects with namespaced `XPlatformSecret` XR objects.
- `crossplane/xrds/platform-cluster.yaml`: removing `claimNames:` deletes the `PlatformCluster` CRD. The live `clusters/platform/platform-cluster-claim.yaml` claim and the `platform-cluster-claim` ArgoCD Application both break immediately.

**Additional structural note:** `crossplane/policies/09-platform-secret-namespace-allowed.yaml` matches `kind: PlatformSecret` without specifying `apiGroups:`. After v2 migration removes the `PlatformSecret` CRD, Kyverno will no longer find any resources matching that kind and the rule will silently become a no-op. This is not a schema rejection but a logic gap: the namespace-restriction enforcement disappears unless the policy is updated to match the replacement kind (`XPlatformSecret`) or namespaced access is enforced via RBAC instead.
