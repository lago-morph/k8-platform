# Spec: `live-kube-read-via-argocd-and-ci`

- **ID**: SKILL-SPEC-5b122d19e1
- **Source retrospective**: ../2026-06-06-162.md

## Intent

When the cluster's kube-API is unreachable from the agent's sandbox (private-CA
serving cert the egress gateway can't verify; `--insecure-skip-tls-verify` just
makes the gateway 503), the agent still needs authoritative live state — XR
conditions, composed managed-resource status, provider/SA wiring, CRD schemas — to
diagnose GitOps/Crossplane stalls. This skill packages the two read paths that
worked in auto-011: the ArgoCD REST resource API (for app-managed resources) and a
reusable read-only `kube-diagnose` CI workflow (for arbitrary cluster reads),
avoiding the kubectl dead-end every session otherwise rediscovers.

## Trigger

Activate when: a kubectl call fails with `x509: certificate signed by unknown
authority` or `the server is currently unable to handle the request`; the handoff
says "kube-API is private-CA blocked"; or you need live XR/MR/provider state and
`kubectl get` times out. Negative trigger: kube-API is directly reachable (just use
kubectl).

## Inputs

- An ArgoCD endpoint + login token (`argocd login`; token in `~/.config/argocd/config`).
- A GitHub repo with Actions + AWS creds in secrets, and a way to write `.github/workflows/` (jentic/ext-github if the git OAuth token lacks `workflow` scope).
- The target resource coordinates (app name, namespace, kind, group, version) or a read-only script.

## Outputs

- Live resource manifests/conditions (ArgoCD API JSON).
- CI job logs containing arbitrary `kubectl`/`aws` read output.
- No cluster mutations (read-only by construction/convention).

## Workflow

1. **App-managed resources → ArgoCD REST API.** `GET https://<server>/api/v1/applications/<app>/resource?appNamespace=argocd&namespace=<ns>&resourceName=<name>&version=<v>&kind=<Kind>&group=<group>` with `Authorization: Bearer <token>`; the response `.manifest` is the live object (parse `.status.conditions`, `.spec.crossplane.resourceRefs`). Extract the token via a YAML parse of the argocd config, not grep.
2. **Composed MRs / arbitrary reads → kube-diagnose workflow.** If absent, author `.github/workflows/kube-diagnose.yml`: `workflow_dispatch` with a `script` input, `aws eks update-kubeconfig`, then `bash -c "$DIAG_SCRIPT"` with the script passed via `env:` (not inline `${{ }}` — injection-safe). Land it via the workflow-scoped path if git OAuth refuses.
3. **Dispatch** with a focused read-only script (`kubectl get managed -n <ns>`, condition jsonpaths, `kubectl get crd <x> -o jsonpath=…` for field verification).
4. **Fetch logs** via the GitHub Actions API; request small `tail_lines` to protect context; route large outputs to a file and `jq`/`python` slice them.
5. Iterate the script, not the workflow.

## Concrete examples

1. **XR stalled, why?** ArgoCD API on `platform-cluster-claim` returned
   `XPlatformCluster` with `Synced=False: Unsynced resources: cluster-cert-validation-record`
   and 11 `resourceRefs` — proving the XR composed but MRs weren't reconciling.
2. **MR-level error.** kube-diagnose script `kubectl get roles.iam.aws.m.upbound.io -n platform -o jsonpath='{…conditions…}'` returned
   `cannot get referenced ProviderConfig: ClusterProviderConfig … default not found`
   — the exact root cause, unobtainable via the ArgoCD app API (composed MRs aren't in the app tree).

## Anti-patterns

- Retrying kubectl with `--insecure-skip-tls-verify` (the gateway 503s on the upstream leg).
- Fetching full CI job logs into context (overflow); always `tail_lines` / file+slice.
- A diagnose workflow that interpolates the script inline (`bash -c '${{ inputs.script }}'`) — shell-injection; pass via `env:`.
- Treating the kube-diagnose workflow as mutating — keep it read-only by convention.

## Acceptance criteria

- Returns a live resource's `.status.conditions` without kubectl access.
- Surfaces composed-MR errors not visible through the ArgoCD app tree.
- Workflow is read-only and injection-safe; large logs never overflow agent context.

## Files this skill creates / modifies

- `.github/workflows/kube-diagnose.yml` — reusable read-only kube diagnostic.
