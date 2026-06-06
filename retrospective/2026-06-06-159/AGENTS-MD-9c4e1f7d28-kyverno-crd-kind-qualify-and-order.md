# agent instruction

A Kyverno `ClusterPolicy` that matches a Custom Resource kind MUST (a)
**group-qualify** the kind as `Group/Version/Kind` (e.g.
`argoproj.io/v1alpha1/AppProject`, `rds.aws.m.upbound.io/v1beta1/Instance`),
never a bare `Kind`, and (b) only be applied AFTER that CRD is Established on the
cluster. Kyverno's `validate-policy` admission webhook converts every matched
kind to a GVR; a bare CRD kind has no group, yielding "unable to convert GVK to
GVR ... failed to find resource (*/*/<Kind>/)" and the policy apply fails. When
the CRD is installed asynchronously (e.g. by a Crossplane provider), the
provider step must `kubectl wait --for=condition=established crd/<plural>.<group>`
(after the provider is Healthy) and the policy-bundle apply must `depends_on`
that step — otherwise the policy races the CRD and fails the same way even when
qualified. Built-in Kubernetes kinds (Pod, Ingress, ClusterRoleBinding, …) are
resolvable unqualified and need neither treatment.

# justification

auto-010 (PR #159): policy 11 matched bare `AppProject` and broke the management
apply at the kyverno-policy step (run 27071480486). Qualifying to
`argoproj.io/v1alpha1/AppProject` fixed it (the ArgoCD CRD is installed
synchronously by its helm chart). Policy 12 then matched the RDS `Instance` CRD,
which provider-aws-rds installs asynchronously — even qualified it would have
failed because the CRD wasn't present at apply time; adding a CRD-Established
wait to the provider step + `depends_on` made it apply cleanly (run 27072048311:
"xdatabase-rds-constraints created"). Guard: `test_kyverno_crd_kinds_qualified.sh`
fails any policy matching a bare CRD kind.
