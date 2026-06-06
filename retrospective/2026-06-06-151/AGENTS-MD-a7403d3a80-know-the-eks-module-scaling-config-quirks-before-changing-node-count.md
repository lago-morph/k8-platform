# agent instruction

**Know the eks module scaling-config quirks before changing node count.** "In terraform-aws-modules/eks, desired_size is ignored after create, so bumping it is a no-op — use min_size to force a higher floor. AWS also rejects min_size > desired_size, so raise desired via aws eks update-nodegroup-config before applying a higher min."

*Grounded in: 2026-06-06 — a desired_size bump planned as 0-change; then min_size=3 apply failed with "Minimum capacity 3 can't be greater than desired size 2".*

# justification

Scaling the management node group from 2 to 3 cost three CI round-trips because of two undocumented-in-context module behaviors discovered the hard way. First, raising `var.node_desired_size` produced `Plan: 0 to change` — the module sets `ignore_changes` on `desired_size` (autoscaler-friendly), so the knob a reader reaches for is inert; `min_size` is the actual lever. Second, applying `min_size=3` then failed at AWS with `Minimum capacity 3 can't be greater than desired size 2`, because the module leaves `desired` at its current value — so the order of operations matters: scale `desired` to the target via `aws eks update-nodegroup-config` first, *then* apply the higher `min`. Each discovery was a failed ~18-minute apply on a degraded cluster. One sentence of forewarning saves both round-trips and tells the next session exactly which lever to pull and in what order.
