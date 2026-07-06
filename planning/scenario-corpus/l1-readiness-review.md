# L1 readiness review — wave-1 scenarios vs the published docs site

**What this is:** the recorded result of the docs-blindness thought
experiment run 2026-07-06, before pointing real scenario sessions at the
site. Six independent, docs-blind review agents were given ONLY the
published site (<https://lago-morph.github.io/k8s-platform/>) plus the
charter's L1 definition, and asked to draft each wave-1 scenario from
`scenario-brainstorm.md` to L1. This file records the verdicts, the
cross-cutting defects, what was fixed immediately (the PR that carries
this file), what became open-issue register entries, and the catalog
corrections proposed for owner ratification.

**Owner ruling incorporated (2026-07-06):** scenario 1 (rebuild from
nothing) is **user-facing** — the platform owner is a user, and
bring-up is a product surface, not development scaffolding. The docs'
"public surfaces" line must include the surface that *creates* the
platform. The build-from-nothing how-to therefore exists (as
`contract` until a human-executed run proves it) rather than being
excluded by an audience rule.

## Verdicts (20 scenarios, at review time — before this PR's fixes)

| # | Scenario | Verdict | Dominant gap |
|---|---|---|---|
| 1 | Rebuild from nothing | NOT WRITABLE | No bring-up page existed (fixed: `how-to/build-the-platform-from-nothing`, `contract`) |
| 2 | Verify a finished build blind | PARTIAL | No expected-state inventory (fixed: `reference/finished-platform`); access acquisition; SSO/observability advertised but unverifiable |
| 3 | Onboard a tenant | PARTIAL | Objective answered by the page; repo-access mechanics + fact acquisition undocumented (partially fixed) |
| 4 | Deploy via GitOps | WRITABLE | kubectl-acquisition contradiction (fixed); no external-repo example (fixed, one-liner) |
| 5 | Expose with hostname+TLS | WRITABLE | Domain discovery; dig answer shape (fixed) |
| 6 | Database + connect app | PARTIAL | **No cross-cluster consumption contract for XDatabase** (OI-2026-07-06-1; limitation now stated on both pages) |
| 7 | Platform secret + consume | WRITABLE | Held end-to-end (the exemplar page) |
| 8 | Health + URL | WRITABLE | Tenant-credentialed access to the Argo CD surface (identity phase); domain discovery (fixed) |
| 9 | Update + confirm rollout | WRITABLE | No latency bound for timeouts (fixed) |
| 10 | Offboard cleanly | PARTIAL | No offboarding procedure; DNS records NOT removed (`upsert-only` — now documented); namespace fate; allowlist reversal |
| 11 | Upgrade add-on, no impact | WRITABLE | Component inventory (fixed via `reference/finished-platform`) |
| 12 | Add new component | WRITABLE (spoke) | Hub-destined components (the catalog's Kargo example) have NO documented path — see catalog proposals |
| 13 | Roll back component change | WRITABLE | — |
| 14 | Rotate platform secret material | WRITABLE (expected-finding) | Delete/recreate semantics unstated (fixed) |
| 15 | Investigate degraded app | PARTIAL | Metrics/logs blocked on the storage gap (OI-2026-06-11-3) — known, honest |
| 16 | Tenant A reads tenant B | NOT WRITABLE as cataloged | Docs document the boundary's ABSENCE; no denial oracle exists (OI-2026-07-06-2) — see catalog proposals |
| 17 | Deploy from disallowed repo | WRITABLE | Exact repo-denial string unpinned (docs now say to capture it on first run) |
| 18 | Cluster-scoped beyond whitelist | WRITABLE | CRB is allow-listed and the backstop is audit-only (OI-2026-07-06-3; page now says so); named denied example added |
| 19 | Author demo: contrast tour | PARTIAL | Blog series unlinked from the site; "tutorial cluster" baseline undefined; SSO/observability beats not executable |
| 20 | Author demo: secrets story | WRITABLE | 5-vs-6 resource enumeration mismatch (fixed: reference table is canonical) |

Tally at review time: 12 writable / 6 partial / 2 not writable. After
this PR's fixes the expected tally is 15–16 writable; the residue is
identity-phase work (2, 8 partial legs), the storage gap (15), phase-6
(none in wave 1), and the catalog corrections below.

## Cross-cutting defects found (and where each landed)

1. **Access acquisition + kubectl contradiction** (hit 8 scenarios):
   the tutorial and health pages required tenant kubectl that the
   onboarding page said doesn't exist; no page said how anyone obtains
   a kubeconfig or the domain value. → **Reported as a defect, not
   papered over** (owner ruling 2026-07-06: "operator hand-grant ==
   defect"): OI-2026-07-06-5 registered, and the affected pages now
   mark access-dependent steps as blocked-on-documentation instead of
   presenting the hand-grant as a procedure. Scenario authors keep
   counting these as blocked-on-docs until the identity phase — whose
   `contract` pages are the next authored wave — publishes the real
   path.
2. **XDatabase cross-cluster consumption gap** — the connection Secret
   lands on the management cluster; tenant workloads run on spokes;
   no contract bridges them (the platform's own consumer uses bespoke
   plumbing). → OI-2026-07-06-1 (product); limitation stated on both
   database pages (docs).
3. **Cross-tenant secret readability** — deterministic ASM names + a
   cluster-wide ClusterSecretStore mean tenant A can plausibly commit
   an ExternalSecret against `k8-platform/<tenant-B-ns>/<name>`;
   nothing documented (or, per source review, implemented) scopes it.
   → OI-2026-07-06-2 (product, security-relevant); stated in
   tenant-boundaries Known limits.
4. **ClusterRoleBinding escalation vector** — the kind is
   allow-listed; the Kyverno backstop AUDITS, it does not block. The
   "airtight whitelist" claim was overstated. → OI-2026-07-06-3
   (product); page wording corrected.
5. **No human-executable bring-up procedure** — the owner ruling
   above; bring-up existed only as CI/agent tooling. →
   OI-2026-07-06-4 (product: close by executing the documented human
   path on a fresh account, which also flips the new page to
   `stable`); page written in this PR.
6. **DNS record lifecycle** — ExternalDNS runs `policy: upsert-only`:
   records are created but never removed. Offboarding leaks DNS
   records BY CURRENT DESIGN. → documented on the hostnames page;
   folded into the teardown/offboarding gap (scenario 10's residue).
7. **Precision fixes** (all in this PR): dig answer shape;
   merge→Synced planning bound; secret delete/recreate semantics;
   canonical created-objects enumeration; landing-page SSO/
   observability claims qualified; denied-kind example; external-repo
   deploy variant one-liner.

## Catalog corrections proposed (owner ratifies; catalog untouched)

- **#16**: objective as written ("isolation boundaries hold and
  denials are observable") cannot be authored against a platform that
  documents the boundary's absence. Propose re-casting as an
  expected-finding scenario (like #14): "attempt cross-tenant reads;
  document that nothing denies them; the finding forces the
  per-tenant-isolation requirements conversation."
- **#12**: split into 12a (spoke component — writable today) and 12b
  (hub/management-plane component, e.g. Kargo — no documented or
  implemented path; expected finding until one exists).
- **Actor mapping**: the site's personas are tenant / operator /
  engineer. Catalog `tenant-admin` and `tenant-dev` both map to
  *tenant* (the docs make no admin/dev distinction yet); `owner` maps
  to *operator*. Scenario authors should use this mapping until the
  identity phase gives the distinction teeth.
- **#1**: stays in the catalog unchanged (owner ruling) — now backed
  by the `contract` bring-up page; L2+ maturation waits for the page
  to flip `stable` (a human-executed clean build), which is exactly
  OI-2026-07-06-4's close condition.

## Method note

Each agent swept the full site (21 pages, sitemap-verified), was
forbidden local repo access, and returned per-scenario L1 skeletons
with page-cited steps plus missing-fact lists. Agent outputs converged
independently on defects 1–4 (two agents each found the kubectl
contradiction and the enumeration mismatch without shared context),
which is the signal the docs-blindness design is meant to produce.
The residual per-scenario gaps in the table are the seed backlog for
the corpus's blocked-on-docs metric.
