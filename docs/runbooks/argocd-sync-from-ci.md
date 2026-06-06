# Runbook — drive ArgoCD app sync from CI (§10.1)

**Why this is a doc, not a workflow file:** in the auto-007 environment, neither
`git push` (OAuth token lacks `workflow` scope) nor the GitHub MCP App (404 on
workflow paths) could commit a file under `.github/workflows/`
(OI-2026-06-05-6). And the Claude-Code-web sandbox could not reach ArgoCD
directly (proxied egress 503; OI-2026-06-05-5) even though ArgoCD is healthy from
CI. So the reusable CI-driven sync mechanism is delivered here for a maintainer
(or a workflow-scoped context) to add.

## What it does

Reads the ArgoCD admin credential from the management Terraform state in S3 and
runs `argocd app sync <app>` from a GitHub-hosted runner (which has unrestricted
egress + the AWS secrets). This is the AGENTS §10.1 method. Reusable for
`platform-cluster-claim` (phase 3) and every spoke add-on app (phases 3-6).

## Install

1. Create `.github/workflows/argocd-app-sync.yml` on `main` with the YAML below.
2. Dispatch it: Actions → "ArgoCD App Sync" → Run workflow → `app=platform-cluster-claim`.
   (Or, with a workflow-scoped CLI: `gh workflow run argocd-app-sync.yml -f app=platform-cluster-claim`.)
3. Then follow `decisions/auto-009-phase3-live-completion-runbook.md` from step 1's
   verification onward (the XR provisions the platform EKS cluster + ACM cert ~20 min).

## The workflow

```yaml
name: ArgoCD App Sync

on:
  workflow_dispatch:
    inputs:
      app:
        description: "ArgoCD Application name to sync"
        required: true
        default: platform-cluster-claim
      wait_health:
        description: "Wait for the app to reach Healthy (off for long EKS provisions)"
        required: false
        default: "false"
        type: choice
        options: ["false", "true"]

permissions:
  contents: read

jobs:
  sync:
    runs-on: ubuntu-latest
    env:
      AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}
      AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
      AWS_REGION: ${{ secrets.AWS_REGION }}
      AWS_DEFAULT_REGION: ${{ secrets.AWS_REGION }}
      APP: ${{ inputs.app }}
    steps:
      - name: Install argocd CLI
        run: |
          set -euo pipefail
          curl -sSL -o /tmp/argocd \
            https://github.com/argoproj/argo-cd/releases/download/v2.13.1/argocd-linux-amd64
          sudo install -m 0755 /tmp/argocd /usr/local/bin/argocd
          argocd version --client --short

      - name: Read ArgoCD credential from Terraform state (§10.1)
        run: |
          set -euo pipefail
          ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
          STATE="s3://k8-platform-tfstate-${ACCOUNT}/k8-platform/management/terraform.tfstate"
          aws s3 cp "$STATE" /tmp/mgmt.tfstate >/dev/null
          URL=$(jq -r '.outputs.argocd_url.value // .outputs.argocd_server_url.value' /tmp/mgmt.tfstate)
          PW=$(jq -r '.outputs.argocd_admin_password.value' /tmp/mgmt.tfstate)
          if [ -z "$URL" ] || [ "$URL" = "null" ] || [ -z "$PW" ] || [ "$PW" = "null" ]; then
            echo "FAIL: argocd_url / argocd_admin_password not found in management state"; exit 1
          fi
          echo "::add-mask::$PW"
          echo "ARGOCD_HOST=${URL#https://}" >> "$GITHUB_ENV"
          echo "ARGOCD_PW=$PW" >> "$GITHUB_ENV"

      - name: Login + sync
        run: |
          set -euo pipefail
          argocd login "$ARGOCD_HOST" --username admin --password "$ARGOCD_PW" --grpc-web
          echo "── before ──"; argocd app get "$APP" --refresh -o wide || true
          if [ "${{ inputs.wait_health }}" = "true" ]; then
            argocd app sync "$APP" --timeout 1800
            argocd app wait "$APP" --health --timeout 1800
          else
            argocd app sync "$APP" --async --timeout 600
          fi
          echo "── after ──"; argocd app get "$APP" -o wide
```

## Verifying the platform cluster (no kube-API needed — sandbox-safe)

```sh
aws eks describe-cluster --name k8-platform-services --query 'cluster.status'      # ACTIVE
aws acm list-certificates --query "CertificateSummaryList[?contains(DomainName,'platform.')]"
aws acm describe-certificate --certificate-arn <arn> --query 'Certificate.Status'  # ISSUED
```
