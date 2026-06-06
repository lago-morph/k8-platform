# auto-007 scope envelope — long-run, phases 3→6

**Run branch (trunk):** `claude/long-run-phases-3-6-7icMB` (PRs stack off this).
**Mandate (user, 2026-06-05):** "Finish phase 3 and do as much of phases 4, 5,
6 as you can." Fresh AWS account; creds refreshed in GitHub CICD secrets AND as
env vars in the sandbox (AWS CLI usable for diagnosis). Build the live stack;
modify Terraform to create credentials for any service installed so the session
can reach it later.

This is a delegated long run under `.claude/skills/autonomous-run`. §6.5
repeat-back is suspended (throughput mode, AGENTS §6.6); decisions that would
normally prompt the user get a decision brief + two adversarial review rounds.

---

## Ground truth verified this session (live API, not handoff belief)

- **Account `730335382332`**, user `cloud_user`, region `us-east-1`. Sandbox
  creds work **after stripping a leading space** the injector added
  (`AWS_ACCESS_KEY_ID` was 21 chars→20, secret 41→40). Helper:
  `/tmp/awsenv.sh` (ephemeral, no secrets in it).
- **Fresh & empty account (AGENTS §8.4):** only the Route53 zone
  `730335382332.realhandsonlabs.net.` exists. No state bucket, no lock table,
  no EKS. Every phase is `code-only` on this account until re-applied.
- **PR #142 is already MERGED to main** (`534a0ce`) — the 3 phase-1 fixes
  (vendored Crossplane chart, provider-wait, label-agnostic SA check) are on
  main. ArgoCD tracks main, so the live rebuild starts from a good base.
- Phase-3 cluster code exists on main (`platform-cluster` XRD/Composition,
  `clusters/platform/`, ArgoCD app `platform-cluster-claim`). **Phase-3 spoke
  is NOT started** — `platform-services/{ingress,external-dns,observability,
  keycloak,...}` are empty `.gitkeep` stubs.

> ⚠️ Possible CI-creds risk: the sandbox creds carried a leading space. If the
> **GitHub Actions secret** was set with the same leading space, CI's in-
> Terraform AWS calls will fail with `IncompleteSignature`. Separate injection
> path, likely fine — the phase-0 dispatch fails fast (§8.5) and will tell us
> within ~2 min. Flagged as a morning-review item if it bites.

---

## 1. What I plan to do

- **Finish phase 3 (live):** rebuild 0→1→2 on the fresh account via CI; sync the
  `platform-cluster-claim` (drive ArgoCD from the sandbox via the §10.1
  Terraform-output cred); build the hub-spoke — spoke registration, ingress-nginx,
  ExternalDNS, hello app, ApplicationSet — and verify `https://hello.platform.<domain>`
  (REQ-PLAT-02/03/04/06).
- **Phase 4 (observability):** author Prometheus + Grafana + Loki on the platform
  cluster, Alloy/agent on management, annotation-driven scraping, ArgoCD-managed
  (REQ-OBS-01..05). Deploy live as far as the platform cluster allows.
- **Phase 5 (auth):** author Keycloak on the platform cluster federated to the
  Cognito pool from phase 0, ArgoCD + Grafana SSO, EKS OIDC provider config,
  prefixed-group ClusterRoleBindings (REQ-AUTH-01..10).
- **Phase 6 (workload cluster):** author a workload-cluster XR + ApplicationSet
  delivering the full add-on stack to a `workload1.<domain>` spoke
  (REQ-WL-01..05).
- **Credential-as-Terraform-output discipline:** for every service installed
  whose API I need to reach, create a credential in Terraform and expose it as an
  output (the ArgoCD §10.1 pattern), so the session can drive it directly.
- **Tests alongside every component** (AGENTS §6.1): unit, kubeconform, render
  fixtures, chainsaw, integration — each preceded by §6.4 adversarial subagent
  review.

## 2. What I plan to NOT do (boundaries)

- **No teardown** of any phase (AGENTS §5 invariant 1). The run only builds.
- **No flipping `platform-cluster-claim` to auto-sync** — manual-sync stays; the
  agent performs the sync itself (handoff Phase-3 sync note).
- **No production hardening / cost optimization / multi-tenancy isolation** —
  out of scope per REQUIREMENTS §3.2.
- **No rotation of the GitHub Actions secrets** — I can't write them from here;
  if they're broken I surface it, I don't paper over it.
- **No rename churn** of v1-era `*-claim` artifact names mid-run (handoff
  follow-up #5) — orthogonal, deferred unless it blocks.

## 3. Scale estimate

- **PRs:** target 12–20 stacked PRs (envelope; phase-3 spoke split into
  registration / ingress+dns / hello+appset; phase-4 obs split into hub stack /
  spoke agent / dashboards; phase-5 keycloak / SSO wiring / EKS-OIDC; phase-6
  workload XR / appset; plus the morning summary). Cap 30.
- **Subagents:** ≥2 adversarial reviewers per test-drafting point (§6.4); a few
  research/fanout agents. Order ~20–40 total.
- **Duration:** a long unattended run. Live CI critical path alone is ~1h+
  (base ~3m → mgmt ~20m → chainsaw ~15m → platform cluster ~20m) before the
  spoke is live; phases 4–6 author in parallel against that.

## 4. First decision points (brief + 2 review rounds when reached)

1. **Phase-4 obs stack shape:** kube-prometheus-stack (Prometheus+Grafana+
   Alertmanager) + loki + alloy, vs lighter-weight. Best answer: the
   community `kube-prometheus-stack` + `loki` (single-binary) + `alloy` agent,
   ArgoCD-managed. Rewind: revert the phase-4 PR(s).
2. **Phase-5 Keycloak DB:** ephemeral (in-pod H2/dev) vs RDS/Crossplane-managed
   Postgres. Best answer: a Crossplane-provisioned small Postgres (realistic;
   matches "production-like" goal), with ephemeral as the fallback if RDS quota
   bites. Brief before committing.
3. **Phase-6 cluster XRD reuse:** reuse `XPlatformCluster` as-is for the
   workload cluster (subdomain-parameterized) vs a distinct `XWorkloadCluster`.
   Best answer: reuse `XPlatformCluster` parameterized by subdomain. Rewind:
   the phase-6 PR.
4. **Cross-cluster cert-ARN injection mechanism (spoke ingress):**
   ApplicationSet param from XR `status.certificateArn` vs a sync pre-hook.
   Best answer: ApplicationSet list/plugin generator carrying the ARN. Finalized
   live against the real cluster (handoff §D).

## 5. What lands as morning-review items

- Any of the four decision briefs whose adversarial rounds did NOT converge.
- The GitHub-Actions-creds leading-space question, IF the phase-0 dispatch fails
  on `IncompleteSignature`.
- Live-verification gaps: any phase whose code is authored + CI-green but whose
  live convergence I could not confirm before the run ended (with the exact
  next command to confirm it).
- Suggested merge order for the whole stack.

## 6. Stop conditions

- Context-budget approaching ~70% → write summary + retro, then continue if able.
- Hard dependency failure (GitHub unreachable, creds broken in CI and
  unfixable from here, subagent harness errors) — try resilience recovery first.
- A destructive op outside scope would be required (halt + ask).
- 30-PR cap hit.
- User countermands in chat.

Building is the default. A closed sub-phase is not a stop condition — start the
next one.
