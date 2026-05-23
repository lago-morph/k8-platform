# AGENTS.md suggestion: Wait=false for charts whose readiness is testable end-to-end

## Proposed addition

> **§10.3 `wait = false` for charts with end-to-end readiness
> checks.** When adding a `helm_release` whose readiness is
> independently testable via either an integration test
> (`tests/integration/`) or an e2e check, set `wait = false` and
> `timeout = 600` on the `helm_release`. Reasoning: a chart that
> blocks Terraform on pod-Ready waits couples the Terraform layer
> to chart implementation detail (image pull, init container,
> webhook reconciliation), producing failure modes that look like
> Terraform timeouts but are actually chart-internal.
>
> `wait = true` (the helm provider default) is the right choice
> only when no downstream test will catch a not-Ready chart and
> Terraform must surface it.
>
> *Grounded in: phase-1 ExternalDNS install hanging on
> `wait = true` for 5 minutes with bitnami chart misconfiguration,
> producing a Terraform timeout that obscured the actual cause.
> Upstream chart with `wait = false` + e2e verify caught the same
> issue in 30 seconds.*

## Why this earns its place in your agents file

The default of `wait = true` is the helm provider's safe choice,
but it coalesces two distinct failure modes (Terraform problem vs
chart problem) into one timeout signal. Once the e2e layer is in
place (which the project has), `wait = false` is strictly better —
the chart install is fast and the verify layer catches the real
runtime concern. The rule prevents new agents from defaulting back
to `wait = true` out of habit.
