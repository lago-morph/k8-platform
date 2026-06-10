# agent instruction

**Confirm the relay target cluster before any mutating kubectl command.** Before issuing a mutating `kubectl` command through the SSM relay (`kubectl create`, `apply`, `delete`, `patch`, `label`, `annotate`), confirm that the `-c <cluster>` flag matches the intended cluster by running a read-only probe first — for example, `kubectl get nodes -c <cluster>` or echoing the active context. The hub (`k8-platform-mgmt`) and the spoke (`k8-platform-services`) are both reachable through the same relay helper, and the `-c` flag is the only differentiator. A mutating command issued with the wrong `-c` flag silently operates on the wrong cluster; there is no rejection or warning.

*Grounded in: auto-016 — the agent ran `kubectl create namespace` through the relay with `-c k8-platform-mgmt` (hub) while intending to operate on the spoke, creating namespaces on the wrong cluster.*

# justification

In auto-016 the agent issued a `kubectl create namespace` command through the SSM relay intending to act on the spoke (`k8-platform-services`), but passed `-c k8-platform-mgmt` (the hub). The command succeeded silently — the relay accepted it, kubectl reported the namespace created, and there was no error. The namespace was created on the hub, not the spoke. The agent did not notice immediately; the discrepancy only surfaced when a subsequent spoke-side operation did not find the namespace it expected.

The failure mode is particularly dangerous because (a) `kubectl create` on the wrong cluster is not reversible without a subsequent `kubectl delete` on the correct cluster, (b) the relay gives no indication which cluster was actually targeted beyond echoing the `-c` value back, and (c) when debugging a multi-cluster operation, an unexpected namespace on the hub is easy to overlook.

The marginal cost of adopting this rule: one `kubectl get nodes -c <cluster>` call before any mutating command — 2–5 seconds, one line of output that confirms the node names and cluster identity. The cost of not adopting it: namespace/resource contamination on the wrong cluster, which must be diagnosed and cleaned up, and which can cause false-green observations (the resource exists, just on the wrong cluster).
