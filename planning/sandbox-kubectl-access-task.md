# Focused task — give the sandbox direct `kubectl` (all clusters)

**What this is:** a standalone, ready-to-run task for one focused agent session.
It implements the sandbox-kubectl access that was assessed feasible in
`ai/handoff.md` (the "NEXT PHASE — give the sandbox direct kubectl" section). That
section is the feasibility analysis; this is the build spec. ~Read both.

---

## How to run this session (model-aware orchestration)

You (the main agent) are **opus, acting as the orchestrator**. You own the design
call, the synthesis, and the final review. Spawn subagents and **pick each
subagent's model for the task to optimize speed without sacrificing quality** —
follow the **`model-aware-dispatch`** skill. **Do not use fast mode**; optimize via
model choice. This is for speed, not token savings.

Suggested split for *this* task (adapt as you go):

| Subtask | Model | Why |
|---|---|---|
| AWS recon (endpoint, IPs, IAM identity, existing ACM cert + zone), reading our terraform/Composition | **haiku** | mechanical, well-specified, verifiable |
| The gateway-websocket / TLS-handshake validation spike (run the candidate, report what happened) | **haiku** (drive it) → **you** interpret | running + reporting is fast hands; the verdict is yours |
| Authoring the Terraform / Composition wiring for the chosen front-end | **sonnet** | self-contained build to a clear spec |
| Drafting tests + the kubeconfig helper + docs updates | **sonnet** | medium-judgment, self-contained |
| **The SSM-tunnel-vs-NLB design decision and final review** | **opus** (you) | load-bearing; do not delegate the judgment |

Run independent subtasks in parallel (one message, multiple `Agent` calls).

## Goal

Let the sandbox run `kubectl` directly against the cluster API, instead of routing
every live read through the `kube-diagnose` CI workflow + the ArgoCD REST API.
Wanted **for every cluster we create** (hub + spokes), so the mechanism belongs in
the `XPlatformCluster` Composition, not a one-off on the hub.

## The shape of the solution (settled by the feasibility assessment)

- **Ruled out:** giving each cluster a publicly-trusted *API-server* cert. EKS is a
  managed control plane; AWS owns that cert and exposes no knob to replace it or to
  put a custom domain on the `*.eks.amazonaws.com` endpoint. Do **not** spend time
  here, and do **not** move off managed EKS to get it.
- **The approach:** a **non-cluster AWS resource that fronts the kube API with a
  publicly-trusted cert** (so the Anthropic egress gateway, which verifies upstream
  certs against public roots, accepts the connection — the same reason ArgoCD needed
  a public ACM cert). The per-cluster ACM cert the Composition already mints and the
  Route53 zone are the building blocks to reuse.
- **The open design decision (yours to make at spike time):** which front-end. Two
  finalists from the assessment:
  - **SSM Session Manager port-forward tunnel** — full kubectl, nothing
    internet-facing added, and kubectl verifies the *real* cluster CA (no cert
    substitution). Needs a tiny SSM-registered instance per VPC. **Unknown to test
    first:** does the egress gateway permit the SSM data-channel websocket?
  - **NLB with a TLS listener (public ACM cert) → the EKS endpoint** — full kubectl
    via L4 passthrough, no standing compute, but the EKS endpoint sits behind
    AWS-managed IPs so the NLB target needs an IP-refresh mechanism.
  - (Lambda function URL is viable only for plain CRUD kubectl — it breaks
    `exec`/`port-forward` — so treat it as a fallback, not a finalist.)

## Steps

1. **Validate before building for all clusters.** On the existing hub, stand up the
   *minimum* of your chosen front-end and prove the egress gateway accepts it and
   `kubectl get nodes` returns. The gateway-websocket question is the single thing
   that decides SSM-vs-NLB — **test it first**, then pick.
   - SSM: stand up one SSM-managed instance; from the sandbox run
     `aws ssm start-session ... AWS-StartPortForwardingSessionToRemoteHost
     host=<eks-endpoint> portNumber=443 localPortNumber=8443`; point kubeconfig at
     `https://localhost:8443`.
   - NLB: one NLB + the ACM cert + a target group at the hub endpoint; point
     kubeconfig at the public NLB host.
2. **Wire auth.** kubectl needs a valid token: the sandbox has AWS creds and runs
   `aws eks get-token`; the cluster needs an **EKS access entry** for the sandbox's
   IAM identity (`user/cloud_user`) with read RBAC. (Same access-entry work already
   tracked for the CI identity — see the handoff owner-decision #2.)
3. **Build it into the Composition for all clusters.** Fold the chosen resource into
   `XPlatformCluster` next to the ACM `Certificate` it already provisions, so every
   hub and spoke gets it automatically. Add a small kubeconfig helper/script the
   sandbox uses to connect.
4. **Address the security posture.** A public-cert proxy adds an internet-facing
   kube-API surface — restrict it with the EKS public-access CIDR allowlist (to the
   gateway egress IPs, if stable) on top of IAM/access-entry auth. The SSM tunnel
   adds no public listener (strictly better) — if you pick it, note that the auth
   gate is IAM + the access entry.
5. **Test + verify against the real cluster** (per AGENTS §6 — verify what you
   built, coupled to the change), and update `ai/handoff.md` to mark this phase done
   and point at the test-strategy continuation as the next phase.

## Acceptance criteria

- [ ] `kubectl get nodes` (and a `kubectl get`/`describe`) works from the sandbox
      against the hub cluster, through the chosen front-end.
- [ ] The mechanism is in the `XPlatformCluster` Composition, so a newly-created
      spoke gets sandbox-reachable kube access without manual steps.
- [ ] Auth is via `aws eks get-token` + an access entry for the sandbox identity
      (no static kubeconfig secrets committed).
- [ ] The security posture is addressed (CIDR allowlist for a public front, or the
      no-public-listener SSM path) and written down.
- [ ] Validated live, with the evidence recorded; handoff updated to hand off to the
      test-strategy continuation.

## Guardrails / NON-GOALs

- Do **not** move off managed EKS or try to replace the API-server cert.
- Respect the test-overhaul security NON-GOALs already in the repo (no probe pod, no
  trust widening, no new principal impersonating the controller) — this work is
  orthogonal but don't undercut them.
- **Validate before generalizing:** prove the mechanism on the hub before wiring it
  into the Composition for all clusters.
- Standard discipline: feature branch, commit + push, ready-for-review PR, keep the
  PR current; never commit to `main`.

## Pointers

- Feasibility + the data-path diagram + the front-end comparison table:
  `ai/handoff.md` → "NEXT PHASE — give the sandbox direct kubectl".
- The public-cert-through-the-gateway precedent: `terraform/management/acm-management.tf`
  (ArgoCD's `*.management.<domain>` ACM cert).
- The per-cluster ACM cert to reuse: the `acm.aws.m.upbound.io/Certificate` +
  `CertificateValidation` in `crossplane/compositions/platform-cluster.yaml`.
- Orchestration: the `model-aware-dispatch` skill (model-per-subtask),
  `subagent-prompting` (briefs), `parallel-subagent-fanout` (fan-out mechanics).
