# agent instruction

**Decode generated user-data before applying a node-recycling infra change.** "Before applying any IaC change that recreates or recycles nodes, run plan and DECODE the generated launch-template user-data to confirm it matches the node AMI/bootstrap mechanism and carries the intended settings. A plausible knob can emit the wrong bootstrap format and silently brick every new node."

*Grounded in: 2026-06-06 — `enable_bootstrap_user_data=true` emitted AL2 `/etc/eks/bootstrap.sh` user-data for an AL2023 node group (no maxPods), which would have downed the cluster; caught by decoding the plan.*

# justification

Trying to raise kubelet `maxPods` for prefix delegation, the agent set `enable_bootstrap_user_data=true` + a `cloudinit_pre_nodeadm` block. `terraform plan` showed the node group recycling — but base64-decoding the launch-template `user_data` in the plan revealed it was **AL2 `bootstrap.sh`** format on an **AL2023** AMI (which has no `bootstrap.sh`), and the intended `maxPods` was absent entirely. Applying it would have recycled all three nodes with user-data that fails to bootstrap → the whole management cluster goes down — strictly worse than the degraded state being repaired. The plan "passed"; only decoding the user-data exposed the trap. The marginal cost is one `base64 -d` per node-recycling plan; the cost of skipping it is a cluster-down outage on a change that looked green. This pairs with "no blind applies": plan is necessary but not sufficient when the payload is generated bootstrap data.
