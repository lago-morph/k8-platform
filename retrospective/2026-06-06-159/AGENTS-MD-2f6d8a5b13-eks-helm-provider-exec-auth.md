# agent instruction

Configure the Terraform `helm` / `kubernetes` providers that target a
freshly-created EKS cluster with the `aws eks get-token` **exec** plugin, never a
static `data.aws_eks_cluster_auth.<x>.token`. EKS bearer tokens expire after 15
minutes; the static token is minted once during apply-graph evaluation, so if
the EKS control-plane create (or any earlier resource) takes longer than ~15 min,
every `helm_release` that runs afterward fails with "Kubernetes cluster
unreachable: the server has asked for the client to provide credentials". The
exec plugin mints a fresh token per operation and cannot expire mid-apply. The
exec block needs `api_version = client.authentication.k8s.io/v1beta1`,
`command = "aws"`, `args = ["eks","get-token","--cluster-name",<name>,"--region",<region>]`;
the runner's AWS creds are inherited from the environment.

# justification

auto-010 (PR #159, run 27070902703): the management apply created the EKS control
plane in an unusually slow 18m53s, after which all four `helm_release`s
(ingress-nginx, eso, crossplane, kyverno) failed on the credentials error. The
node group (the change actually under test) had come up fine — the failure was
purely the expired static token. Switching `versions.tf` to exec auth made the
next apply pass cleanly. This is a latent fragility on every EKS bring-up: it
only manifests when the control plane is slow, so it hides until a bad-luck run.
Pinning exec auth removes the whole class. Gated by a tripwire in
`test_eks_module_defaults.sh`.
