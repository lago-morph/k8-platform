# agent instruction

**Give every child AWS provider an explicit IRSA `runtimeConfigRef`.** "In the Upbound family model each child provider (eks/iam/acm/route53/secretsmanager/rds) runs its own pod under its own ServiceAccount. Set `spec.runtimeConfigRef` on every child Provider to the IRSA-annotated DeploymentRuntimeConfig (so its pod runs under the role-annotated, trust-admitted SA); otherwise the pod has no web-identity token and every managed resource fails with `token file name cannot be empty`."

*Grounded in: auto-011 blocker #3 — only the upbound-provider-family-aws SA had the role-arn annotation; all child provider pods lacked IRSA.*

# justification

The terraform installed the family Provider with a DeploymentRuntimeConfig pinning an IRSA-annotated ServiceAccount, but the six child providers were installed as bare `Provider` objects with no `runtimeConfigRef`. A kube-diagnose pod/SA dump proved each child ran under its own un-annotated SA, so none received `AWS_WEB_IDENTITY_TOKEN_FILE`, and — because the crossplane role's trust is `StringEquals` on the single family subject — none could assume the role. Every cluster managed resource stalled with `token file name cannot be empty`, again with no cloud-side error. Adding one `runtimeConfigRef` block per child provider (a few terraform lines) eliminates an entire class of "MR never reconciles and AWS shows nothing" stalls that otherwise cost ~30 minutes of CI-mediated diagnosis to localize.
