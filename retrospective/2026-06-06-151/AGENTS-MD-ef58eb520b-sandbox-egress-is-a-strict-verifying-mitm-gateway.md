# agent instruction

**Sandbox egress is a strict-verifying MITM gateway.** "Treat sandbox outbound HTTPS as passing through a gateway that terminates TLS and strictly verifies the UPSTREAM cert. A service you exposed is reachable only if it presents a publicly-trusted cert whose SAN matches the host; private-CA endpoints and SAN-mismatched certs 503 and need CI. Diagnose with openssl s_client + the 503 body."

*Grounded in: 2026-06-06 — ArgoCD 503'd on a SAN gap and kubectl 503'd on the EKS private CA, both at the egress gateway.*

# justification

The session burned significant time treating two distinct symptoms as separate mysteries: ArgoCD returned `503 … verify SAN list` and every kube-API call returned `503 … unable to get local issuer certificate`. Both are the *same* cause — the sandbox's egress gateway terminates TLS (it presents a leaf signed by `O=Anthropic, CN=Egress Gateway SDS Issuing CA`) and re-originates with strict upstream verification. So a service is reachable from the sandbox only when its upstream cert is publicly-trusted *and* its SAN covers the host; the base `*.<acct>` wildcard didn't cover `argocd.management.<acct>` (fixable: issue a covering cert), and the EKS API's private CA can never be verified (not fixable: use CI). Knowing this up front collapses a class of "why can't I reach X" investigations into two `openssl s_client` calls and a read of the 503 body (`verify SAN list` = fixable SAN gap; `unable to get local issuer certificate` = private CA, CI-only). It also corrects the prior handoff's misleading "ArgoCD is directly reachable" claim.
