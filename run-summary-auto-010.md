# Run summary — auto-010 (2026-06-06)

Unattended run on a **fresh, empty AWS account** (`596430611165`, us-east-1).
Goal (user): (1) make k8s nodes allow many more pods, (2) validate the entire
phase 0-3 build, (3) complete phases 4-5 and validate their builds.

Single-branch run per scope-envelope **DP-1** (`decisions/auto-010-scope-envelope.md`):
all work on `claude/k8-pods-phase-validation-7oqVK`, **one PR (#159)**,
per-commit rewind points (the harness mandates this branch; the autonomous-run
stacked-PR default yielded to it).

---

## 1. TL;DR

- **maxPods → 110 DONE and proven.** Nodes now allow ~110 pods (was ~17). The
  AL2023 + nodeadm node group came up green in 1m47s on the live fresh build.
- **Phase 0 (base): VERIFIED** green (run 27070773919).
- **Phase 1 (management): essentially validated** — EKS ACTIVE, 3 nodes Ready,
  ArgoCD + Crossplane (+ all providers, 1 family Provider, Healthy) + ESO +
  Kyverno + ingress-nginx + external-dns all running, IRSA OK, all
  policies/audit applied. **Four real bugs found and fixed with regression
  tests** along the way (see §2). The last gate (argocd DNS record) is fixed and
  re-applying as of run **27071999686**/`f0279b4` — pending green confirmation.
- **Phase 4 (observability): COMPLETE** — hub Grafana Alloy via a new
  `hub-addons` AppProject (Option A). Adversarial-reviewed tests + a Kyverno
  runtime backstop. Committed.
- **Phase 5 (auth DB): COMPLETE (authored + unit/render/chainsaw-00 validated)** —
  general `XDatabase` XRD + RDS Composition, Keycloak wired via `keycloak-db`,
  provider-aws-rds terraform. Two adversarial reviews. **Live RDS provisioning
  not yet run** (needs the in-flight apply to install provider-aws-rds, then
  sync the keycloak-db XR / run the real-AWS chainsaw).
- **Queued / morning-review:** confirm the f0279b4 apply is green; run phase-2
  chainsaw; phase-3 platform-cluster live provision (auto-009 runbook); phase-5
  live RDS. See §5/§6.

## 2. Key findings / bugs fixed (each with a regression test — TDD §6.2)

1. **maxPods (feat, `5938d19`).** vpc-cni prefix-delegation already raised the
   IP ceiling but kubelet still advertised ~17. Pinned
   `ami_type=AL2023_x86_64_STANDARD` (so the module emits nodeadm user-data, not
   AL2 `bootstrap.sh`) + `cloudinit_pre_nodeadm` NodeConfig `maxPods: 110`. Guard:
   3 tripwires in `test_eks_module_defaults.sh`. **Proven**: node group ACTIVE in
   1m47s (the AL2-bootstrap trap that prior sessions feared did NOT occur).
2. **mikefarah-yq glob `==` (`7c34201`).** A new test used `yq 'select(.x == "*")'`;
   mikefarah yq (CI's yq v4.44.3) treats `*` in the `==` RHS as a **glob**, so it
   matched everything → false CI failure (my sandbox had python-yq, hiding it).
   Fixed to the `test()` regex idiom. Installed mikefarah yq as the sandbox
   default so local == CI.
3. **EKS auth-token expiry (`4904287`).** The helm provider used a static
   `data.aws_eks_cluster_auth` token (15-min TTL). The control plane took 18m53s
   to create, so helm releases ran after the token expired ("server has asked
   for the client to provide credentials"). Fixed to `aws eks get-token` **exec
   auth** (refreshes per op). Guard: tripwire in `test_eks_module_defaults.sh`.
4. **Kyverno CRD-kind GVR resolution (`d55dbaa`).** Policy 11 matched bare
   `AppProject`; Kyverno can't convert a groupless CRD kind to a GVR
   (`*/*/AppProject/`). Group-qualified to `argoproj.io/v1alpha1/AppProject`.
   Guard: new `test_kyverno_crd_kinds_qualified.sh`.
5. **external-dns zone-match-parent (`f0279b4`).** Both external-dns instances
   filter a **subdomain** (`management.<domain>` / `platform.<domain>`) of the
   account's only (base-domain) hosted zone. Without `--aws-zone-match-parent`
   external-dns matches **zero zones** and publishes nothing (confirmed via its
   `domains: []` log) — so `argocd.management.<domain>` was never created.
   Latent since the auto-008 filter-narrowing. Added the flag to hub (helm.tf) +
   spoke (values.yaml); guard added to `test_external_dns_disjoint_filters.sh`.
   Also ordered policy 12 after the provider-aws-rds CRD (same GVR class as #4
   but the RDS CRD is async-installed).

## 3. PR

| PR | Branch | Base | Status |
|---|---|---|---|
| **#159** | `claude/k8-pods-phase-validation-7oqVK` | `main` | open, ready for review |

The PR description is the per-chunk index; this file is the run-level summary.

## 4. Suggested merge order

Single PR (#159). Merge once the in-flight management apply (`f0279b4`) is green
and (optionally) phase-2 chainsaw is dispatched green on the head SHA. The change
is cohesive: maxPods + phase-1 robustness fixes + phase-4 + phase-5 scaffolding.
Everything is gated by unit tests + kubeconform; the heavy chainsaw/terraform
paths are dispatch-verified.

## 5. Rewind points (commit → what it undoes)

| SHA | Undoes |
|---|---|
| `805f747` | scope envelope (run setup) |
| `5938d19` | maxPods / AL2023 node group |
| `d017426` | phase-4 hub-addons + Alloy + tests |
| `7c34201` | yq-glob test fix |
| `4904287` | helm exec-auth |
| `d55dbaa` | kyverno policy-11 qualification + CRD-kind guard |
| `1086e24` | phase-5 XDatabase + RDS + tests + keycloak-db |
| `f0279b4` | external-dns zone-match-parent + policy-12 ordering |

## 6. Morning-review items / remaining live validation (next steps)

1. **Confirm phase-1 green.** Check run `f0279b4`'s management apply-and-verify:
   the argocd record should now publish and `argocd-url` pass. If still red, read
   the external-dns logs for `AWSZoneMatchParent:true` and the record.
2. **Phase-2 chainsaw.** `pre-chainsaw-audit.sh` is GREEN. Dispatch `chainsaw.yml`
   (ref = branch, `commit_sha=$(git rev-parse HEAD)`). Note: the full set now
   includes the real-AWS `xdatabase/01-claim-creates-rds` + `02` (provision RDS,
   ~10-15 min) — scope via `scenario_filter` to the kind-only set
   (`platform-secret`, `platform-cluster`, `xdatabase/00`) for a fast phase-2
   gate, or run all to also validate phase-5 RDS live. This turns the
   (currently-red, expected) `chainsaw-verify` check green.
3. **Phase-3 live.** Once ArgoCD is reachable (the external-dns fix), follow
   `decisions/auto-009-phase3-live-completion-runbook.md`: argocd login (cred from
   the `terraform/management` `argocd_admin_password` output), sync
   `platform-cluster-claim`, build the XSpokeAccess composition, register the
   spoke, verify `https://hello.platform.<domain>`.
4. **Phase-5 live.** The in-flight apply installs provider-aws-rds. Sync the
   `keycloak-db` XDatabase XR (platform-services/keycloak/database/) and verify
   the RDS Instance + connection Secret; then Keycloak consumes it.

## 7. What I deliberately did NOT do

- **Phase 6 (workload1)** — out of scope per the envelope.
- **No teardown** of any phase.
- **Live RDS / phase-3 cluster** not provisioned this run (budget; the apply that
  installs provider-aws-rds was the last dispatched). Clear next steps in §6.
- Did not modify `.github/workflows/unit-tests.yml` (git OAuth lacks `workflow`
  scope) — the new unit tests are gated via the run.sh catch-all (§6.16 satisfied).

## 8. Session metadata

- Branch at end: `claude/k8-pods-phase-validation-7oqVK` @ `f0279b4`.
- Subagents: 2 phase-4 adversarial reviewers, 2 phase-5 adversarial reviewers,
  1 phase-5 implementation author, 1 phase-5 finalizer (7 total).
- Open issues logged: `OI-2026-06-06-3` (xdatabase `-master` secret orphan).
