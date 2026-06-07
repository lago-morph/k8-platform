---
name: sandbox-kubectl-access
description: >-
  Use when running kubectl from the Anthropic sandbox against any cluster in
  this account. Trigger phrases: "kubectl from the sandbox", "get nodes",
  "read the live cluster", "describe pods", "kube-diagnose alternative",
  "why does kubectl 503", "can't reach the API server", "check the cluster
  state", "watch ArgoCD applications", "list Crossplane XRs live".
allowed-tools:
  - Bash
  - Read
---

# Sandbox kubectl access via SSM tunnel

Direct `kubectl` from the sandbox 503s at the egress gateway because EKS API
servers present a cluster-private-CA certificate that the gateway cannot verify
against public roots. The fix is an AWS SSM Session Manager port-forward tunnel:
the gateway accepts the public `ssmmessages.amazonaws.com` WebSocket, kubectl
sends genuine TLS through the transparent TCP relay, and the real cluster CA is
verified end-to-end. See `docs/decisions/0006-sandbox-kubectl-via-ssm-tunnel.md`
for the full decision record.

## Usage

### One-shot command (recommended)

```sh
scripts/sandbox-kubeconfig.sh -c <cluster-name> --exec kubectl get nodes
```

Replace `kubectl get nodes` with any read-only kubectl command.
The script opens the SSM tunnel, runs the command against that cluster,
then tears the tunnel down.

Examples:

```sh
scripts/sandbox-kubeconfig.sh -c mgmt-hub --exec kubectl get pods -A
scripts/sandbox-kubeconfig.sh -c platform-spoke --exec kubectl get applications -n argocd
scripts/sandbox-kubeconfig.sh -c platform-spoke --exec kubectl get xplatformclusters -A
```

### Interactive session

To use kubectl interactively (multiple commands against one cluster):

```sh
eval "$(scripts/sandbox-kubeconfig.sh -c <cluster-name>)"
kubectl get nodes
kubectl describe pod <name> -n <ns>
# ... more commands ...
scripts/sandbox-kubeconfig.sh --stop   # tear down the tunnel when done
```

`eval` exports KUBECONFIG and KUBECTL_TUNNEL_PID into the current shell.
Always call `--stop` when finished to clean up the background SSM process.

## Prerequisites

The following must be present in the shell environment:

- `session-manager-plugin` — AWS SSM Session Manager plugin for the AWS CLI
- `kubectl` — Kubernetes CLI
- `jq` — JSON processor (used internally by the helper script)
- AWS credentials with `ssm:StartSession` on the relay instance and
  `eks:DescribeCluster` / `eks:GetToken` on the target cluster
  (`user/cloud_user` in standard sandbox sessions already has these)

## Access level

kubectl sessions are **read-only**. The sandbox IAM identity (`user/cloud_user`)
is mapped to `AmazonEKSAdminViewPolicy` via an EKS access entry on every
cluster. This grants read access to all resources including CRDs (Crossplane
XRs, ArgoCD Applications, Secrets metadata) but **no write access**. Mutations
must go through ArgoCD or CI — do not attempt to `kubectl apply` or `kubectl
delete` from a sandbox session.

## How it works

`scripts/sandbox-kubeconfig.sh` calls `aws ssm start-session` with the
`AWS-StartPortForwardingSessionToRemoteHost` document, targeting the single
shared relay `t3.nano` in the base VPC; the SSM data channel is a WebSocket to
`ssmmessages.<region>.amazonaws.com`, which carries a public AWS certificate
the egress gateway accepts. The relay opens a raw TCP connection to the
cluster's private EKS endpoint; kubectl sends TLS directly through that pipe
and verifies the real cluster CA — no certificate is substituted or terminated.
Token issuance is via `aws eks get-token`; no static kubeconfig secrets are
committed.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `No relay instance found` | The relay EC2 hasn't been created yet | Ensure `terraform/management` has been applied (`terraform apply` in that directory or wait for CI) |
| `Waiting for connections` never progresses / tunnel hangs | SSM agent on the relay is down or the relay instance is stopped | Check instance state in EC2 console; restart the instance or the SSM agent |
| `kubectl` connects but cluster not listed / `Unauthorized` | The cluster's per-cluster SG ingress rule or EKS access entry is missing | Verify the `XPlatformCluster` Composition rendered `kube-relay-ingress` and `sandbox-access-entry` for that cluster (`kubectl get managed -o wide` on the hub); re-sync the ArgoCD app if needed |
| Gateway 503 despite the tunnel | Traffic is not going through the tunnel; KUBECONFIG still points at the direct endpoint | Confirm `eval "$(scripts/sandbox-kubeconfig.sh ...)"` ran in the current shell, or use `--exec` form |

## References

- `docs/decisions/0006-sandbox-kubectl-via-ssm-tunnel.md` — full ADR
- `terraform/management/kube-access.tf` — relay instance, relay SG, hub access entry
- `crossplane/compositions/platform-cluster.yaml` — `kube-relay-ingress`,
  `sandbox-access-entry`, `sandbox-access-policy` per platform cluster
- AGENTS.md §6.27 — sandbox egress gateway TLS verification policy
