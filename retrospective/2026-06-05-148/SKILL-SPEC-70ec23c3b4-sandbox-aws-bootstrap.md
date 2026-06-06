# Spec: `sandbox-aws-bootstrap`

- **ID**: SKILL-SPEC-70ec23c3b4
- **Source retrospective**: ../2026-06-05-148.md

## Intent

Bring a fresh Claude-Code-web sandbox to a working "I can diagnose live AWS +
clusters" state in one pass, and surface the reachability boundaries before any
work depends on them. In auto-007 this was done ad hoc and cost several false
starts: the AWS CLI wasn't installed, the injected creds had a leading space that
broke SigV4, kubectl couldn't validate the EKS private CA, and ArgoCD was
unreachable from the sandbox though healthy from CI. Each was discovered
mid-task. A single bootstrap routine turns those into a known map at session
start.

## Trigger

- Session start of any run that will use AWS CLI / kubectl / argocd from the
  sandbox (the user says "use AWS CLI to diagnose", "build live", "long run").
- Proactively when `aws`, `kubectl`, `helm`, or `argocd` is invoked and returns
  "command not found", or when an AWS call returns `IncompleteSignature` /
  `SignatureDoesNotMatch`.
- Negative: skip for pure code-only sessions with no live AWS/cluster intent.

## Inputs

- Sandbox env vars (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION`).
- Optional: a target EKS cluster name + an internet-facing service URL
  (e.g. ArgoCD) to probe.

## Outputs

- A sourceable `/tmp/awsenv.sh` exporting sanitized creds + a PATH for the
  installed tools.
- Installed `aws`, `kubectl`, `helm`, `argocd`, `kubeconform`, `terraform` (only
  the ones the session needs).
- A printed reachability map: account id, region, hosted zone; which of
  {AWS API, EKS kube-API, ArgoCD URL} are reachable from the sandbox.

## Workflow

1. `env | grep '^AWS_'`; for each cred var, check length — `AWS_ACCESS_KEY_ID`
   must be 20, `AWS_SECRET_ACCESS_KEY` 40. If longer, strip with
   `tr -d '[:space:]'`. Write the sanitized exports + a tool PATH to
   `/tmp/awsenv.sh`.
2. Install only the needed tools to a writable dir (`/usr/local/bin` via sudo, or
   `/tmp/bin`): aws (awscli v2 zip), kubectl (dl.k8s.io), helm (get.helm.sh),
   argocd (github release), kubeconform, terraform. Verify each `--version`.
3. `aws sts get-caller-identity` — confirm account + identity. If it fails with a
   signature error, re-check step 1's stripping.
4. Probe reachability and record each result, labelled observation/exclusion:
   - AWS API: the `sts` call above (works → reachable).
   - EKS kube-API: `aws eks update-kubeconfig` then `kubectl get ns`; a
     `x509: certificate signed by unknown authority` means the private CA is
     unreachable through the sandbox proxy — mark kube-API as CI-only.
   - A public cluster service (ArgoCD): `curl -sS -o /dev/null -w '%{http_code}'
     https://<url>/healthz`; a 503/403 with clean TLS means proxied egress — mark
     it sandbox-unreachable and plan to drive it from CI.
5. Print the map and the implications ("kube ops → CI", "ArgoCD sync → CI") so
   downstream steps don't assume a blocked path works.

## Concrete examples

1. **auto-007 cred fix.** `env` showed `AWS_SECRET_ACCESS_KEY` len 41; stripping
   the leading space made `aws sts get-caller-identity` return
   `730335382332 … user/cloud_user`. Without it, every call returned
   `IncompleteSignature: Invalid key=value pair (missing equal-sign) in
   Authorization header`.
2. **auto-007 reachability map.** `kubectl get nodes` → `x509: unknown authority`
   (private CA, CI-only); `curl https://argocd.management.<domain>/healthz` → 503
   with clean TLS (proxied egress, CI-only) while a CI `management verify` saw
   200. The map said "platform-cluster sync must run from CI", which was the
   correct conclusion and is captured in `docs/runbooks/argocd-sync-from-ci.md`.

## Anti-patterns

- Concluding "creds are stale/rotated" from a sandbox signature error (it's a
  whitespace artifact; CI creds are independent — verify via a `verify` dispatch).
- Declaring a tool "unavailable" before attempting the one-line install (§6.12).
- Assuming a runbook's "reachable from the sandbox" claim holds for THIS sandbox.

## Acceptance criteria

- After running, `source /tmp/awsenv.sh && aws sts get-caller-identity` succeeds.
- The reachability map correctly classifies kube-API and any public service as
  reachable or CI-only, with the evidence (TLS error / HTTP code) recorded.
- No AWS call in the rest of the session fails on `IncompleteSignature`.

## Files this skill creates / modifies

- `/tmp/awsenv.sh` — sourceable sanitized creds + tool PATH (ephemeral, no
  secrets baked into the repo).
