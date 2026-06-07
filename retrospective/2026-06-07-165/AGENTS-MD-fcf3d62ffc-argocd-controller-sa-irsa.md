# agent instruction

**Annotate every ArgoCD component SA that makes AWS calls with the IRSA role, not just the server.** "The ArgoCD application-controller (not the server) authenticates to managed clusters; annotate BOTH argocd-server and argocd-application-controller ServiceAccounts with eks.amazonaws.com/role-arn and ensure both are in the IRSA role trust policy, or spoke syncs fail with argocd-k8s-auth exit 20 IMDS timeouts."

*Grounded in: auto-012 — cluster registration via the server succeeded but every spoke app sync failed because the controller SA had no IRSA.*

# justification

A maddening asymmetry made this expensive to find: the argocd-server validated the spoke cluster fine during `POST /api/v1/clusters` (it had the IRSA annotation), so registration reported `connectionState: Successful` — but the application-controller, which performs the actual app sync, had no annotation, fell back to IMDS, and every sync failed with `argocd-k8s-auth exit 20 (Client.Timeout exceeded while awaiting headers)`. The helm.tf comment even claimed "the server SA is the one that needs the annotation," which was wrong. The IRSA trust policy already listed both SAs; only the helm annotation was missing. Annotating the controller SA and rolling its pod (the pod-identity webhook injects the token only at pod creation) is a one-line fix once identified; diagnosing it required a kube-diagnose comparison of the two SAs' annotations.
