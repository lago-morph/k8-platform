# ADR-0010 Adversarial Review — Contract Completeness & Producer-Side Feasibility

Angle: does the 4-fact contract (domain, certificate-arn, external-dns-role-arn,
region) actually cover every OVERLAID-AT-REGISTRATION value, and can the hub-side
producer obtain each fact? All claims verified against the tree.

Repo file count note: `argocd/apps/spoke/` has TEN files, not "nine". Nine are
spoke-destination; `observability-alloy-mgmt.yaml` is a HUB app
(`observability-alloy-mgmt.yaml:46-49`, project hub-addons). The ADR says "nine
spoke Applications carry committed placeholders" (line 13) — defensible if alloy
is counted separately, but the prose conflates the dir count with the spoke count.
See MINOR-1.

---

## BLOCKER-1 — Keycloak's externalDatabase.host/port are OVERLAID-AT-REGISTRATION but are NOT in the 4-fact contract, and they originate from a DIFFERENT XR (XDatabase), not XPlatformCluster/XSpokeAccess.

Claim under test: ADR Context table + Decision assert the per-cluster facts reduce
to four (domain, certificate-arn, external-dns-role-arn, region), all produced by
XPlatformCluster / XSpokeAccess.

Evidence:
- `platform-services/keycloak/values.yaml:62-63`:
  `host: PLACEHOLDER_DB_HOST  # overlaid at registration from XR status.endpoint`
  and `port: 5432  # overlaid at registration from XR status.port`.
- `argocd/apps/spoke/keycloak.yaml:13-16` lists "externalDatabase.host if
  account-specific" as an OVERLAID-AT-REGISTRATION value (the question explicitly
  flagged this).
- The producer is the **XDatabase** XR, whose connection Secret is `keycloak-db`
  and whose `status.endpoint`/`status.port` are surfaced (keycloak values
  comment, and `crossplane/xrds/xdatabase.yaml` is a distinct abstraction). This
  is neither XPlatformCluster nor XSpokeAccess.

Why it's a BLOCKER: the ADR's central thesis is "the contract is per-cluster
complete; ApplicationSets may only reference contract keys; the producer must
emit exactly the contract keys" (Consequences, lines 100-104). keycloak NEEDS two
values the contract has no slot for, sourced from a third XR. Either the
ApplicationSet for keycloak still needs a non-contract fact (breaking the
bidirectional lint), or keycloak's DB host/port overlay silently regresses to the
banned hand-overlay and bootstrap selfHeal re-reverts it — the exact failure mode
this ADR exists to kill. The 4-fact contract is NOT complete.

Suggested fix: either (a) expand the contract to N facts including
`keycloak-db-host`/`port` (and rename away from "4-fact"), explicitly modeling
that some facts come from XDatabase not the cluster XR; or (b) scope keycloak's DB
host/port out of the cluster-Secret mechanism and state how they reach the chart
instead (e.g. ESO ExternalSecret writing them into the keycloak-db Secret the
chart already reads via existingSecret). The ADR must name which.

---

## BLOCKER-2 — `region` has NO existing surfaced producer source; it is neither in the cluster-network EnvironmentConfig nor on any XR status.

Claim under test: ADR Context table line 29 — "`region` | terraform var /
EnvironmentConfig".

Evidence:
- `terraform/management/crossplane-phase3.tf:167-188`: the `cluster-network`
  EnvironmentConfig `data` block carries `privateSubnetIds`, `route53ZoneId`,
  `domain`, `accountId`, `argocdRoleArn`, `relaySecurityGroupId`. There is **no
  `region` key.**
- `crossplane/xrds/platform-cluster.yaml:100-105`: `region` is an XR **spec**
  input that "Defaults to us-east-1". It is consumed (FromCompositeFieldPath
  spec.region → forProvider.region, e.g. platform-cluster.yaml:341-343) but is
  **never written to status** (no `ToCompositeFieldPath ... toFieldPath:
  status.region` anywhere in platform-cluster.yaml).
- Compositions hardcode `region: us-east-1` as the MR base default
  (platform-cluster.yaml:308, 471, 577; xspokeaccess.yaml:294).

Why it's a BLOCKER: the ADR's producer-phasing claim is that PR-2 "assembles
connection facts + these annotations" from the provisioning path (lines 71-77),
and the Consequences claim the producer "must emit exactly the contract keys."
But of the four facts, `region` is the one with NO surfaced source a Secret
producer can read — not on XPlatformCluster status, not on XSpokeAccess status,
not in the EnvironmentConfig. The ADR states the source as fact ("terraform var /
EnvironmentConfig") when the EnvironmentConfig demonstrably does not carry it.

Suggested fix: ADR must state exactly what PR-2 adds: either add `region` to the
`cluster-network` EnvironmentConfig data (crossplane-phase3.tf:167) AND surface it
to XR status, or have the Secret producer read `var.aws_region` directly in the
terraform/Composition path. As written, "region | terraform var /
EnvironmentConfig" is unverified and the EnvironmentConfig half is false.

---

## MAJOR-1 — The producer half (durable cluster Secret) is itself an unbuilt, contradictorily-decided blocker; ADR-0010 layers facts onto an artifact that does not yet durably exist and whose build mechanism is in dispute.

Claim under test: Decision lines 44-47 — facts "ride the ArgoCD cluster Secret …
already planned as the durable registration artifact (OI-2026-06-07-1)"; PR-2 uses
ESO `target.template` to stamp the labels/annotations (lines 71-76).

Evidence:
- `SUBSTRATE-READINESS.md` row 5: "Spoke ArgoCD cluster-Secret durable form
  (OI-2026-06-07-1) | **not built** (live REST/kubectl bootstrap only) |
  blocker." The cluster Secret has NO durable form today.
- `docs/open-issues.md` OI-2026-06-07-1 status line: "open; hand-bootstrapped live
  again in auto-016." And the entry contains TWO conflicting mechanisms: the
  bolded "Resolution: plain ESO … `ExternalSecret` with `target.template`" vs. the
  later "Recommended durable mechanism: add a provider-kubernetes `Object` to the
  XSpokeAccess Composition … assembling `config` JSON via `CombineFromComposite`."
- `docs/decisions/0005-*.md:61-63` explicitly REJECTS provider-kubernetes Object
  for the cluster Secret in favor of ESO target.template — so 0005 and the
  OI-2026-06-07-1 "Recommended" paragraph disagree, and OI-2026-06-07-1's own
  "Resolution" (ESO) contradicts its own "Recommended" (provider-kubernetes).

Why it's MAJOR: ADR-0010's PR-1 (ApplicationSets) is inert and harmless, but its
entire value depends on PR-2 producing a labeled cluster Secret. The ADR asserts
that producer is "already planned" and "the clean build validates both halves" —
but the producer mechanism is itself disputed in the source record and not built.
The ADR should not present the producer as settled; it inherits OI-2026-06-07-1's
unresolved ESO-vs-provider-kubernetes fork.

Suggested fix: ADR must either resolve (or explicitly defer with a named owner)
the ESO-vs-provider-kubernetes producer fork it depends on, and stop describing
the cluster Secret as an "already planned … durable registration artifact" — it
is an open blocker (SUBSTRATE row 5).

---

## MAJOR-2 — ADR claims to close OI-2026-06-07-2 whose recorded decision is the cluster-facts **ConfigMap** (ADR-0005); ADR-0010 reverses that decision but does not mark ADR-0005 as superseded.

Claim under test: ADR line 5 — "Closes: OI-2026-06-07-2 … mechanism decision
deferred"; and Alternatives line 81 rejects the literal ConfigMap.

Evidence:
- `docs/open-issues.md` index row: "OI-2026-06-07-2 | … | decided (ADR 0005
  cluster-facts ConfigMap), not implemented." And SUBSTRATE-READINESS.md row 4:
  "Placeholder overlays vs bootstrap selfHeal (OI-2026-06-07-2, **ADR-0005
  cluster-facts ConfigMap**) | not built — THE keystone."
- `docs/decisions/0005-*.md:48-53`: the binding corollary names "the per-cluster
  **ConfigMap** of cluster facts (OI-2026-06-07-2)" as owned by the cluster
  provisioning path. That is a committed ADR decision, not merely "deferred."
- ADR-0010 line 6 frames the mechanism as merely "deferred," and lines 81-85
  reject the ConfigMap — i.e. it overturns ADR-0005's recorded carrier.

Why it's MAJOR: ADR-0010 changes the carrier of record (ConfigMap → cluster
Secret) but does not list ADR-0005 in a "Supersedes" relationship, and mis-frames
the prior state as "deferred" rather than "decided (ConfigMap)." SUBSTRATE row 4
and the OI index will continue pointing at the ConfigMap. This is a traceability
hole that will leave two contradictory "decided" mechanisms in the record.

Suggested fix: add "Supersedes / amends ADR-0005's cluster-facts ConfigMap
corollary"; update OI-2026-06-07-2 and SUBSTRATE row 4 references (or note they
must be updated by this PR). Reframe line 6 from "deferred" to "ADR-0005 named a
ConfigMap; this ADR replaces that carrier."

---

## MAJOR-3 — workload1 needs DIFFERENT per-cluster facts (distinct cert ARN, distinct external-dns role ARN, distinct subdomain) than the platform spoke; the contract is only complete if it is genuinely per-Secret, and the ADR's "collapse into the same ApplicationSets" understates a real divergence.

Claim under test: Decision lines 60-64 — workload1 files "collapse into the same
ApplicationSets … driven by a second labeled cluster Secret."

Evidence (each workload1 fact is genuinely distinct, not shared):
- Cert ARN: `*.platform.<domain>` vs `*.workload1.<domain>` — produced per cluster
  by each cluster's own ACM cert (platform-cluster.yaml:489-503,
  CombineFromEnvironment over `subdomain`). Two different ARNs.
- external-dns role ARN: per-spoke XSpokeAccess Role
  (xspokeaccess.yaml:160-202, external-name `k8-platform-%s-external-dns`). Two
  different ARNs.
- Subdomain / domainFilters / txtOwnerId / txtPrefix: workload1 uses a SEPARATE
  committed values file `platform-services/external-dns/workload1-values.yaml`
  (workload1-external-dns.yaml:39) with `workload1.<domain>` /
  `k8-platform-workload1` / `_edns-workload1-.`, asserted DISJOINT from hub AND
  platform (`workload1-values.yaml` header table). hello subdomain is `workload1`
  vs `platform` (workload1-hello.yaml:31 vs hello.yaml:25).

Why it's MAJOR: the divergence is fine IF each is read from that cluster's own
labeled Secret (which the cluster-generator does). But two things the ADR glosses:
(1) external-dns uses a per-cluster *values file* (workload1-values.yaml), so the
ApplicationSet template must select the values file by `short-name`, not just
inject facts — the "collapse into the same ApplicationSets" is more than a fact
injection; it is a per-cluster valueFile switch the ADR never describes. (2) The
ADR's "4-fact contract" must be read as per-Secret; the doc's single Context table
lists one producer per fact as if global, which obscures that workload1's cert/role
come from a SECOND XPlatformCluster + XSpokeAccess pair. The contract is
per-cluster-complete only if PR-2 emits a full fact set on EACH Secret.

Suggested fix: state explicitly that (a) facts are per-Secret and PR-2 emits a
complete set per cluster Secret; (b) the external-dns ApplicationSet template must
switch `valueFiles` (or fold the disjoint txt-owner/domainFilter identity into the
contract or a per-cluster values path) keyed on `short-name` — the current
workload1-values.yaml carries stable per-cluster identity that is NOT one of the
four facts and must survive the collapse.

---

## MINOR-1 — "nine spoke Applications" mis-states the directory; one of the ten files is a hub app, and one spoke app (loki) has zero ephemeral facts.

Evidence: `argocd/apps/spoke/` lists 10 files; `observability-alloy-mgmt.yaml:46-49`
is hub-destination (project hub-addons). `observability-loki.yaml:9-11`: "no
account-ephemeral values to overlay … no valuesObject patch at registration."

Why MINOR: doesn't break the mechanism, but the framing "nine spoke Applications
carry committed placeholders" (line 13) is loose — loki carries none, and the alloy
app is not a spoke app. The alloy app DOES need facts (remote_write/Loki push URLs)
but its destination is the hub, so a `cluster-role: spoke` generator will NOT match
it — see MINOR-2.

Suggested fix: tighten the count: of the 10 files, 8 spoke apps need facts (loki
needs none), and 1 is a hub app needing facts via a different selector.

---

## MINOR-2 — The hub alloy app needs spoke-derived facts but its destination is the hub; a `cluster-role: spoke` cluster-generator cannot template it. The ADR hand-waves this.

Claim under test: Decision lines 62-64 — "The hub-destination alloy agent keeps
`destination` = in-cluster hub but templates its spoke-derived URLs from the same
generator."

Evidence:
- `observability-alloy-mgmt.yaml:46-49`: destination is
  `https://kubernetes.default.svc` (the hub), project hub-addons.
- `platform-services/observability/alloy/values.yaml:33-36, 84-110`: needs
  `PLACEHOLDER_SPOKE_PROMETHEUS_REMOTE_WRITE_URL` and
  `PLACEHOLDER_SPOKE_LOKI_PUSH_URL` — both derived from the SPOKE's `<domain>`.
- ArgoCD's cluster generator iterates cluster Secrets and sets the Application
  `destination` to the matched cluster. To deploy to the hub while reading the
  spoke's domain, the generator must match the SPOKE Secret yet override
  destination to hub — a non-obvious template, not "the same generator."

Why MINOR (borderline MAJOR): mechanically awkward and unspecified. A cluster
generator selecting `cluster-role: spoke` yields the spoke as `destination`; the
template would have to hardcode `destination.server: https://kubernetes.default.svc`
while consuming the iterated spoke's `domain` annotation. Feasible, but the ADR
asserts it works without showing the override, and these are derived URLs (domain
+ fixed path), confirming `domain` suffices as the fact — so at least no new
contract key is needed.

Suggested fix: spell out the alloy ApplicationSet: cluster generator selects the
spoke Secret (for `domain`), template fixes destination to the hub and composes the
two URLs from `domain` + the static paths in values.yaml.

---

## VERIFIED-OK (claims that held up)

- `status.certificateArn` EXISTS: platform-cluster.yaml:501-503
  (`ToCompositeFieldPath status.atProvider.arn → status.certificateArn`).
- external-dns role ARN IS surfaced on XSpokeAccess status:
  xspokeaccess.yaml:200-202 (`status.externalDnsRoleArn`). The ADR's claim that
  this fact has a producer is TRUE.
- `domain` IS in the cluster-network EnvironmentConfig:
  crossplane-phase3.tf:170 (`domain = var.domain`).
- ESO `target.template` DOES support metadata labels + annotations:
  `kubeconform-schemas/external-secrets.io/externalsecret_v1beta1.json` —
  `/spec/target/template/metadata/labels` and `.../annotations` both present.
  CAVEAT: whether template values can REFERENCE the pushed remote data
  (`{{ .domain }}` etc.) is an ESO templating-engine behavior NOT encoded in the
  JSON schema — schema only proves the fields exist, not that they interpolate
  remote data. Needs live ESO docs to confirm; ADR treats it as given.
- auto-008 §5 DID design the cert-arn cluster-Secret annotation:
  auto-008-spoke-gitops-delivery.md:46-48, 97 (registration "annotates the spoke
  cluster Secret (`certArn`, `subdomain`, `domain`)"). Note auto-008 names
  `subdomain` as an annotation too — ADR-0010 instead carries subdomain as a
  committed per-app value (hello.yaml:25). Minor divergence, not a defect.
- Inertness: a cluster generator with no matching cluster Secret produces zero
  Application objects; nothing for bootstrap to sync, so no sync error. The
  per-app files were likewise inert (each names a destination that doesn't exist
  until registration, e.g. external-dns.yaml:32-34). The ADR's inertness claim is
  sound. NOT independently verifiable here: the ApplicationSet schema
  `applicationset_v1alpha1.json` is ABSENT from `kubeconform-schemas/argoproj.io/`
  (only application + appproject exist), so PR-1's "kubeconform with the
  ApplicationSet schema" cannot run until that file is added — the ADR
  acknowledges this in Consequences ("gains applicationset_v1alpha1.json"). The
  EMPTY-generator transition question (what happens to already-generated apps when
  a Secret is deleted) is governed by ApplicationSet `preserveResourcesOnDeletion`
  / sync-policy, which the ADR does NOT specify — see MINOR note below.

## MINOR-3 — ADR does not specify ApplicationSet sync-policy / preserveResourcesOnDeletion; the transition behavior when a cluster Secret is removed (or before it exists) is unstated.

Why MINOR: during normal bootstrap the generator is simply empty → no apps, fine.
But if a labeled Secret is later removed/relabeled, the default ApplicationSet
behavior deletes the generated Applications (and their workloads). The ADR claims
"inertness preserved exactly" but an Application that previously existed and is
now generator-removed is a DELETE, not inertness. The blast radius of an
accidental Secret delete is "tear down every spoke add-on."

Suggested fix: specify `syncPolicy.preserveResourcesOnDeletion` (or
`applicationsSync: create-update`) in the ApplicationSet contract so a transient
missing Secret does not cascade-delete live spoke workloads.

---

## SECURITY / BLAST-RADIUS — who can write the cluster Secret in argocd ns; coupling the ADR should name.

Evidence:
- The cluster Secret lives in `argocd` ns on the hub (Decision line 44; auto-008
  C5). Today it is created LIVE via the ArgoCD REST API
  (OI-2026-06-07-1: "created LIVE via the ArgoCD REST API POST /api/v1/clusters").
- The intended durable writer is either ESO (ADR-0005:42-63) OR a
  provider-kubernetes Object run by the XSpokeAccess Composition
  (OI-2026-06-07-1 "Recommended"; crossplane-phase3.tf:228-269 installs
  provider-kubernetes + a hub ProviderConfig `InjectedIdentity` specifically to
  "write the ArgoCD spoke cluster Secret … into THIS management cluster").
- So TWO subsystems are provisioned to write into argocd ns: ESO's
  ClusterSecretStore path and provider-kubernetes' hub ProviderConfig. Both have
  Secret-write in argocd ns.

Coupling the ADR should name (currently unstated):
1. ADR-0010 turns the cluster Secret into ArgoCD's connection credential AND the
   platform's fact bus. Anything that can write annotations on that Secret can now
   redirect every add-on's cert ARN / IRSA role ARN / domain — a privilege
   escalation surface (e.g. point ingress at an attacker-controlled cert ARN). The
   ADR names the contract but not the writer-authorization model.
2. ESO `target.template` REWRITES the whole target Secret. If ESO owns the Secret
   AND it also carries the ArgoCD connection `config`/caData, an ESO template that
   omits a field could clobber the connection data ArgoCD needs — coupling the
   fact-stamping and the connection-credential lifecycles into one object with one
   owner. This is exactly why OI-2026-06-07-1 needed target.template to assemble
   caData-in-JSON; layering fact annotations on the same template increases the
   blast radius of a template bug from "stale facts" to "ArgoCD loses the cluster."

Suggested fix: ADR should add a Consequences bullet naming (a) the single writer
of record for the cluster Secret and the RBAC that restricts argocd-ns Secret
writes to it, and (b) that fact-annotations and ArgoCD connection data now share
one object/one template owner — and how a partial template write is prevented.

---

## SEVERITY COUNT
- BLOCKER: 2
- MAJOR: 4
- MINOR: 3
- (plus 1 SECURITY/coupling finding and a VERIFIED-OK section)
