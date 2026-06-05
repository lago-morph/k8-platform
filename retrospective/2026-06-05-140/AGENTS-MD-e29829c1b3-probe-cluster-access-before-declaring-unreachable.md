# agent instruction

**Probe for cloud and cluster access before declaring the cluster unreachable.** Before claiming you cannot reach the cluster/ArgoCD/cloud, actually probe: AWS_* env vars, ~/.aws, IMDS (169.254.169.254), $KUBECONFIG and ~/.kube, a test call to a cloud API endpoint, and any credential-brokering MCP. Report the specific failure (no creds vs blocked egress vs missing tool). If the install path for driving the service is to expose its credentials as a Terraform output, prefer that over asserting impossibility.

*Grounded in: 2026-06-05 phase-3 — agent repeated a stale "can't kubectl" claim; user said "you have access or can generate ArgoCD credentials."*

# justification

The agent carried forward a prior session's "sandbox can't reach the cluster" note as if it were a standing fact, instead of probing. When it finally probed (per §6.12), it found the precise truth — egress works, credentials don't exist — which is materially different from "can't reach it" and points at the real fix (create + output ArgoCD creds, drive via CI). The probe is five cheap commands; the cost of skipping it was an inaccurate capability claim the user had to challenge, and a near-miss on the better design (ArgoCD credentials as a Terraform output).
