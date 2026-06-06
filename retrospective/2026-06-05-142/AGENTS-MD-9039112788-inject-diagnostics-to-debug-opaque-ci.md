# agent instruction

**When a CI provisioner/step fails opaquely and you have no live cluster/API access, inject a best-effort diagnostics dump and re-run before hypothesizing.** "Rather than guess at remote state from the sandbox, add a non-fatal dump of the actual state to the failing step (e.g. `kubectl get deploy,sa --show-labels`, pod `serviceAccountName`s, `get providers,providerrevisions` — each `|| true`), push, re-dispatch, and read the truth from the next run log. Evidence beats hypotheses (§6.17); one extra CI cycle that prints reality is cheaper than several spent speculating."

*Grounded in: 2026-06-05 auto-005 — a diagnostics dump revealed the v2.5.0 provider Deployment label-less shape that fixed the apply.*

# justification

Without cluster access, the agent burned a CI cycle on a wrong hypothesis (a package-manager race) before a one-time diagnostics dump showed the real cause (a non-matching label selector). Injecting `get … --show-labels` / pod-SA output into the failing step and re-running surfaced ground truth in a single cycle. The marginal cost is a few `|| true` lines that stay useful for future debugging; the cost of guessing is multiple wasted cycles and hypothesis-as-conclusion errors the user has flagged before.
