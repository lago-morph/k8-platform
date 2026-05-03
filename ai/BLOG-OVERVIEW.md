# Blog Series — Overview and Intent

**Series working title:** Real-World Kubernetes: From Tutorial to Production Architecture
**Status:** Outline approved, not yet written

---

## Purpose

This series addresses a specific gap in Kubernetes educational content. There is abundant material covering how to use Kubernetes as a tenant — deploying applications, writing manifests, understanding pods and services. There is very little material covering the architectural decisions that go into building the platform those applications run on.

The series is built around a real reference implementation (see the companion GitHub repository) that demonstrates a production-like multi-cluster platform on AWS. The git repository covers the "how exactly." The blog series covers the "why" and the "what are the alternatives."

---

## Intended Audience

**Primary persona 1 — The experienced tenant.** Someone who has used Kubernetes clusters extensively but always as a user of someone else's platform. They understand the technologies involved but have not had to make the architectural decisions. They want to upgrade their understanding to where they could design and build a platform from scratch.

**Primary persona 2 — The organic cluster admin.** Someone who has grown a Kubernetes environment incrementally, adding components as needed, without an upfront architectural plan. They are living with the consequences of those decisions — inconsistent auth, manual certificate renewals, no clear secrets strategy — and want to understand the root causes well enough to either refactor gradually or design a deliberate v2.

**What these readers have in common:** They do not need basic Kubernetes concepts explained. They understand what cert-manager is. What they lack is understanding of how and why these components combine architecturally to achieve specific outcomes.

**Tone implication:** Do not explain the technologies. Explain the decisions — why this technology in this role, what breaks if you don't have it, what you would choose differently in different circumstances.

---

## Writing Approach

### Decisions over instructions

Each post focuses on an architectural decision: what problem it solves, what the alternatives are, what the trade-offs are, and what we chose for this implementation and why. The git repository handles step-by-step implementation. The posts handle reasoning.

### Pros and cons, not right and wrong

Every major decision is framed as contextually appropriate rather than universally correct. We chose X here because of Y and Z constraints. If your constraints are different, A or B might be better. This is more honest and more useful than prescriptive "best practice" framing.

### Embedded failure modes

Rather than a dedicated post on what goes wrong without good architecture, the "what it looks like if you don't do this" is embedded in each decision discussion. The cert-manager post explains what certificate management looks like without it. The Keycloak post explains what per-service SSO integration leads to. This keeps motivation local to the decision.

### Sequential structure with standalone decisions

The posts follow a rough build order — foundational decisions first, then component decisions, then synthesis. But the goal is not for readers to follow along and build. The sequence frames which decisions need to be made early and why. Each decision post should be readable independently by someone who already understands the context.

### No "follow along" dependency

Readers are directed to the git repository for specifics. The posts do not include step-by-step instructions or code blocks. Someone searching for "hub-spoke vs per-cluster ArgoCD" should find the relevant post useful without having read the previous ones.

---

## Series Structure

**10 posts total.** Two open structural questions noted at the end of this document.

Posts 1-2: Framing (why this series exists, the foundational topology decision)
Posts 3-4: The management plane (GitOps as a change mechanism, bootstrapping the manager)
Posts 5-8: The component decisions (secrets, ingress/TLS/DNS, identity, observability)
Post 9: The Crossplane/platform API layer
Post 10: Synthesis and honest assessment of what this does and doesn't solve

---

## Open Structural Questions

1. **Posts 3 and 4** (GitOps and the management cluster bootstrapping problem) may be one post or two. They are related but the bootstrapping problem is distinct enough to stand alone. To be decided during writing.

2. **A components map post** — there may be value in an early post (around Post 2 or 3) that gives readers a map of all the components before diving into individual decisions. This would give context for why each subsequent decision matters. Not currently in the outline but worth considering.
