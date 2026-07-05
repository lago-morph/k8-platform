---
status: contract
---

# Get kubectl access via your directory group

You have an account in the platform's user directory (an email and
password), and your account is in one of the platform's Kubernetes
access groups. This page gets you from that account to a working
`kubectl` — no AWS credentials, no IAM user, no shared kubeconfig
secrets. Your access level comes entirely from your group membership,
and removing you from the group removes the access.

## Before you start

- Your directory account is a member of `k8s-admins` or `k8s-viewers`
  (ask the platform operator — group membership is managed in the
  directory, never inside the platform).
- You know the platform domain (`<domain>` below); the operator hands
  it out with your account.
- `kubectl` is installed, plus the [krew](https://krew.sigs.k8s.io/)
  plugin manager.
- A browser is available on the same machine (the login flow opens
  one).

## 1. Install the OIDC login plugin

```bash
kubectl krew install oidc-login
```

## 2. Add the cluster and login stanza to your kubeconfig

Ask the operator for the platform services cluster's API endpoint and
certificate-authority data (or copy the `cluster:` block from any
existing kubeconfig for that cluster — those fields are public
material, not credentials). Then add:

```yaml
apiVersion: v1
kind: Config
clusters:
  - name: platform
    cluster:
      server: https://<cluster-api-endpoint>
      certificate-authority-data: <cluster-ca-base64>
users:
  - name: platform-oidc
    user:
      exec:
        apiVersion: client.authentication.k8s.io/v1beta1
        command: kubectl
        args:
          - oidc-login
          - get-token
          - --oidc-issuer-url=https://auth.platform.<domain>/realms/platform
          - --oidc-client-id=kubernetes
          - --oidc-extra-scope=profile
          - --oidc-use-pkce
contexts:
  - name: platform
    context:
      cluster: platform
      user: platform-oidc
current-context: platform
```

The `kubernetes` client is public with PKCE enforced — there is no
client secret to obtain, copy, or leak.

## 3. Log in by using kubectl

```bash
kubectl get pods -A
```

The first call opens your browser: the platform's sign-in page
(`auth.platform.<domain>`) forwards you to the directory's login form.
Sign in with your directory email and password. The browser flow ends
on a local success page; the terminal command then completes with the
access your group grants. Tokens are cached — subsequent calls do not
re-open the browser until the session expires.

## 4. Verify who the cluster thinks you are

```bash
kubectl auth whoami
```

Expect your username as `kc:<your-email>` and, under groups,
`kc:k8s-admins` or `kc:k8s-viewers`. The `kc:` prefix marks every
identity that arrived through the directory path — see
[Identity mapping](../reference/identity-mapping.md) for the full
claim-by-claim table.

## What each group grants

| Directory group | Cluster access |
|---|---|
| `k8s-admins` | Full admin (`cluster-admin`) on the platform services cluster |
| `k8s-viewers` | Read-only (`view`) on the platform services cluster |

Access applies to the **platform services cluster**. The management
cluster is deliberately not reachable this way — it stays on the
operator's break-glass path only.

## Revocation and its time bound

Removing your account from the group (or disabling it) in the
directory revokes access at the **next token refresh**: group
membership is re-read from the directory on every fresh login, and a
cached session re-validates within the platform's session bounds. An
operator can terminate a session immediately from the platform's auth
console; without that intervention, assume a revoked account retains
its cached access until the session expires (the platform session
maximum — hours, not days).

!!! info "Break-glass is separate by design"
    Platform operators retain an AWS-IAM-based access path to every
    cluster that does not depend on the directory, the broker, or this
    login flow. A directory or auth-layer outage never locks the
    platform's own operators out.
