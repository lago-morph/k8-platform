# agent instruction

**Verify a Crossplane v2 provider IRSA ServiceAccount by the pod `serviceAccountName`, not by the `pkg.crossplane.io/provider` label.** "The Upbound v2.5.0 family-provider Deployment (`provider-family-aws-<hash>`) carries NO `pkg.crossplane.io/provider` label, so `delete`/`rollout status -l pkg.crossplane.io/provider=provider-family-aws` match nothing even when the Provider is `Healthy`. Wait for `provider.pkg.crossplane.io/<name> --for=condition=Healthy`, then check `kubectl -n crossplane-system get pods -o jsonpath` of `spec.serviceAccountName` includes the expected SA (and the SA object exists). Do not gate on the provider label selector."

*Grounded in: 2026-06-05 auto-005 — a by-label delete/rollout matched nothing on v2.5.0 and failed the management apply.*

# justification

A heavily-commented provisioner gated on `kubectl … -l pkg.crossplane.io/provider=provider-family-aws`, which matches NOTHING on the Upbound v2.5.0 family provider even when it is Healthy — the Deployment carries no such label. That cost two failed management applies before a diagnostics dump revealed the label-less Deployment and its pod running as the pinned SA. Checking the pod's `serviceAccountName` is label-agnostic and verifies the actual IRSA contract, surviving the next provider-version label change.
