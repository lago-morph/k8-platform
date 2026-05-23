# AGENTS.md suggestion: "Tear down phase X" terminology

## Proposed addition

> **§5.1 "Tear down phase X" — precise definition.** When the user
> says "tear down phase X" (or "destroy phase X", "remove phase X",
> equivalent), the scope is exactly:
>
> 1. Delete every Claim that was created from XRDs introduced in
>    phase X. Wait for Crossplane to deprovision the underlying
>    cloud resources (`kubectl wait --for=delete` on each Claim).
> 2. Delete the XRDs / Compositions / supporting manifests
>    introduced in phase X from the cluster.
> 3. Run `terraform destroy` for any Terraform module owned by
>    phase X, in reverse dependency order.
>
> The scope does NOT include:
>
> - Tearing down phase X-1 or anything lower.
> - Touching the management cluster's bootstrap stack (ingress-nginx,
>   ArgoCD, ESO, Crossplane core, ExternalDNS, Kyverno).
> - Deleting state files for phases not being torn down.
>
> If the user wants a broader teardown they will say so
> ("tear down everything", "tear down phase 0 and 1", etc.).
>
> *Grounded in: the 2026-05-23 session's "tear down phase 2"
> ambiguity, which the user resolved as exactly this scope.*

## Why this earns its place in your agents file

I spent a round-trip with the user asking what "tear down phase 2"
meant — whether it included re-running `terraform destroy` on
phase-1 management. The user's answer was clear in retrospect, but
each future agent will run into the same ambiguity if it isn't
encoded. The encoding cost is one section; the recurring
clarification cost is once per future agent that touches phase
teardown.

The rule also has a load-bearing safety property: it explicitly
forbids tearing down anything below the named phase. That property
matches `AGENTS.md §5 invariant 1` (never destroy a phase lower
than the one being worked on) and reinforces it from the
terminology direction.
