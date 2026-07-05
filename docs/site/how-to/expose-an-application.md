---
status: stable
---

# Expose an application with a public hostname and TLS

Give a deployed application a public `https://` URL. On this platform
that is **one Kubernetes Ingress object** — DNS records and the TLS
certificate already exist as platform machinery, so there is nothing
to request and nothing to renew.

## Before you start

- Your application is [deployed](deploy-an-application.md) with a
  `Service` in front of it.
- You know your cluster's subdomain (e.g. `platform`) — your chart
  receives it as `.Values.subdomain` along with `.Values.domain`.

## 1. Add an Ingress to your chart

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: myapp
spec:
  ingressClassName: nginx
  rules:
    - host: "myapp.{{ .Values.subdomain }}.{{ .Values.domain }}"
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: myapp
                port:
                  number: 80
```

Three things that are deliberately **absent**:

- **No `tls:` block.** TLS terminates at the cluster's ingress load
  balancer with the cluster's wildcard certificate
  (`*.<subdomain>.<domain>`); your Ingress speaks plain HTTP behind it.
- **No DNS annotation.** The platform's DNS controller watches Ingress
  rule hosts and creates the Route53 record from the `host:` line.
- **No certificate resource.** There is no cert-manager on this
  platform; certificates come with the cluster.

Keep the hostname **one label** under the cluster subdomain
(`myapp.platform.<domain>`, never `a.b.platform.<domain>`) — the
wildcard certificate covers a single level. The full conventions are
in [Hostnames, DNS, and TLS](../reference/hostnames-dns-tls.md).

## 2. Commit and let it sync

Same loop as any change: merge to `main`, the Application reconciles.

## 3. Verify

```bash
# DNS record exists (allow a minute or two after the sync):
dig +short myapp.<subdomain>.<domain>

# The endpoint answers over verified TLS:
curl -sSf https://myapp.<subdomain>.<domain>
```

`curl` verifying the certificate without flags is the point: a
self-signed or missing cert here is a platform defect, not a step you
skipped.

## Troubleshooting order

1. Application `Synced/Healthy`? (delivery — see
   [health surfaces](../reference/health-surfaces.md))
2. `kubectl -n myapp get ingress` shows your host and an address?
3. DNS: `dig +short` — record creation lags the Ingress by up to a
   couple of minutes on first exposure.
4. Then the backend: pods ready, service endpoints non-empty.
