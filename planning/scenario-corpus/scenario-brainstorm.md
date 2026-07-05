# Scenario brainstorm — seed L0 catalog, ranked by execution order

**What this is:** the founding scenario list for `k8s-platform-scenarios`,
at bullet level (role × verb × surface + a one-line objective). Ranked into
**waves by when the platform can execute them** — wave 1 runs against the
platform as it exists after clean build #4; later waves unlock as features
land. **Describing** any of them (L0→L1) can start immediately and in any
order; the wave only gates L2+ maturation.

Tags: `[owner]` `[tenant-admin]` `[tenant-dev]` `[user]` `[author]` `[adversary]`

---

## Wave 1 — executable against today's platform

**Platform lifecycle (the calibration anchors — already partially matured):**

1. `[owner]` Rebuild the entire platform from nothing on a fresh account.
   *Objective: prove "working" is a property of the repository.* (Already at
   L4 — this is the existing clean-build loop; listed so the corpus contains
   its own gold standard.)
2. `[owner]` Verify a finished build end-to-end without knowing how it was
   built. *Objective: the health-check story is documented and sufficient.*

**Tenant application lifecycle (the core product story):**

3. `[tenant-admin]` Onboard a new tenant: get a namespace, deploy rights,
   and repo wiring. *Objective: discover whether onboarding is a documented
   product operation or undocumented owner hand-work.*
4. `[tenant-dev]` Deploy a stateless web application from a git repo via
   GitOps. *Objective: the minimum deploy path is documented and works.*
5. `[tenant-dev]` Expose that application publicly with a hostname and
   valid TLS. *Objective: ingress/DNS/cert self-service works as documented.*
6. `[tenant-dev]` Claim a database and connect the application to it.
   *Objective: the database abstraction is consumable from docs alone.*
7. `[tenant-dev]` Claim a platform secret and consume it from an
   application. *Objective: the secret abstraction (deterministic naming,
   generated material) is consumable from docs alone.*
8. `[tenant-dev]` Answer "is my app healthy and what's its URL?" using only
   what the platform exposes. *Objective: tenant-facing status story exists.*
9. `[tenant-dev]` Update a deployed application (new image/config) and
   confirm rollout. *Objective: day-2 deploy loop documented.*
10. `[tenant-admin]` Offboard: remove the application and the tenant
    cleanly. *Objective: teardown is a product operation; nothing leaks.*

**Owner change management:**

11. `[owner]` Upgrade one platform add-on (e.g. ingress controller chart
    version) via GitOps and prove no tenant impact. *Objective: the change
    path is documented, observable, and reversible.*
12. `[owner]` Add a new component to the base set (e.g. Kargo). *Objective:
    the extension recipe (app manifest, project whitelist, sync waves) is a
    documented pattern, not archaeology.*
13. `[owner]` Roll back a bad component change. *Objective: git revert →
    converged cluster, with proof.*
14. `[owner]` Rotate the platform's own generated secret material.
    *Objective: EXPECTED FINDING — rotation is deliberately out of scope of
    the current secrets design; this scenario exists to force the
    requirements conversation with a paper trail.*
15. `[owner]` Investigate "why is this application degraded" using platform
    tooling only. *Objective: the debugging story; partially blocked by the
    known storage gap (see wave 3).*

**Adversary (must fail):**

16. `[adversary]` Tenant A reads tenant B's secrets/namespace. *Objective:
    isolation boundaries hold and denials are observable.*
17. `[adversary]` Tenant deploys from a repository outside the allowed set.
    *Objective: the GitOps trust boundary holds.*
18. `[adversary]` Tenant creates cluster-scoped resources beyond the
    whitelist. *Objective: the project whitelist is airtight.*

**Author (blog series, posts writable today):**

19. `[author]` Demo script for the series opener: tutorial-cluster vs this
    platform, the contrast tour. *Objective: the post's demonstration is
    scriptable and every artifact shown is committed.*
20. `[author]` Demo script for the secrets story: one claim → five resources
    → a valued secret readable by a consumer. *Objective: the concept demos
    in a handful of commands; tedium here is a design smell.*

## Wave 2 — needs the identity half (phase 5)

21. `[owner]` Add a person to a directory group; they get working kubectl
    with the mapped role. *Objective: THE phase-5 acceptance test
    (directory → Cognito → Keycloak → EKS).*
22. `[owner]` Remove the person; access is revoked within a stated bound.
    *Objective: offboarding is as real as onboarding.*
23. `[user]` A newly-authorized engineer goes from zero to first kubectl
    command using docs alone. *Objective: the getting-access tutorial works.*
24. `[tenant-dev]` Log into platform UIs (ArgoCD, Grafana) with SSO.
    *Objective: the OIDC client chain serves real logins.*
25. `[adversary]` A user NOT in the group is denied kubectl and UI access.
    *Objective: federation denies as reliably as it admits.*
26. `[author]` Demo script for the identity post. *Objective: the full
    federation chain demos deterministically with a test user.*

## Wave 3 — needs the spoke storage fix (observability un-Pending)

27. `[tenant-dev]` Debug a failing app via its logs and metrics in the
    platform observability stack. *Objective: the tenant debugging story.*
28. `[owner]` Capacity/usage review across clusters. *Objective: the fleet
    view exists and is documented.*
29. `[owner]` An alert fires for a genuinely broken workload; trace it to
    root cause. *Objective: alerting is wired, not just installed.*

## Wave 4 — fan-out (phase 6) and fleet operations

30. `[owner]` Onboard a third cluster by pulling the deliberate-sync gate.
    *Objective: fan-out really is "free" as the ApplicationSet work claims.*
31. `[tenant-admin]` A second tenant lands on the new cluster; placement is
    per policy. *Objective: multi-cluster tenancy story.*
32. `[owner]` Fleet-wide add-on upgrade across all spokes. *Objective: change
    management scales past one cluster.*
33. `[owner]` Retire a spoke cleanly with tenants migrated off. *Objective:
    cluster lifecycle has an exit path.*

## Wave 5 — day-2 depth (order flexible; several are expected findings)

34. `[owner]` Restore a tenant database from backup after data loss.
    *Objective: EXPECTED FINDING territory — backup/restore posture is
    currently undefined.*
35. `[owner]` Account rotation with tenant workloads present: what survives?
    *Objective: force the "intentionally ephemeral vs tenant expectations"
    requirements conversation.*
36. `[tenant-admin]` Hit a resource quota and understand what happened.
    *Objective: quotas exist, are documented, and fail loudly.*
37. `[owner]` Apply and enforce a new policy (e.g. disallow :latest images);
    a violating tenant deploy is rejected with a clear message. *Objective:
    the guardrail loop end-to-end.*
38. `[owner]` Review "who can do what" across the fleet. *Objective: the
    access model is auditable from platform surfaces.*
39. `[author]` Demo scripts for the remaining posts as their subjects land.
    *Objective: every published post stays executable forever.*

---

**Reading the ranking:** waves track *platform capability*, not importance.
Scenarios 14, 34, and 35 are deliberately included although they're expected
to "fail" at the requirements layer — surfacing that with a paper trail is
the corpus doing its job. The blocked-on-docs count across wave 1 after the
first documentation pass is the docs plan's success metric.
