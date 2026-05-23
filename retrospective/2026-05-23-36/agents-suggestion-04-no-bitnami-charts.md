# AGENTS.md suggestion: No bitnami charts in the platform stack

## Proposed addition

> **§10.1 No bitnami charts in the platform stack.** When choosing
> a Helm chart for a new component, do not select the bitnami
> variant. Prefer the upstream chart from the project itself
> (e.g. `kubernetes-sigs/external-dns` not `bitnami/external-dns`).
> If the upstream chart does not exist, prefer a well-maintained
> community alternative; document the choice in the PR description.
>
> *Grounded in: the 2026-05-23 phase-1 attempt with
> `bitnami/external-dns:6.31.0`, which hung at helm install for
> >5 minutes with pods stuck in not-Ready due to a value-shape
> mismatch. Upstream chart with simpler values resolved cleanly.
> User policy stated as: "stay away from bitnami for everything".*

## Why this earns its place in your agents file

Bitnami charts have a tendency to layer their own value-naming and
defaults on top of the upstream project's chart, which produces a
maintenance overhead and silent compatibility problems with the
upstream project's docs. The phase-1 failure was concrete: the
bitnami chart's value structure for AWS provider configuration
didn't match what external-dns 0.14.x actually expected, and the
pods went into a wait loop until helm timed out. Switching to the
upstream chart resolved it in one apply.

The rule's marginal cost is approximately zero — picking a chart is
a one-shot decision per component. The benefit is avoiding silent
chart-shape mismatches.
