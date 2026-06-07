# agent instruction

**Tag shared-VPC ELB-role subnets for every EKS cluster that uses the VPC.** "In a shared-VPC multi-cluster setup, tag the kubernetes.io/role/elb and kubernetes.io/role/internal-elb subnets with kubernetes.io/cluster/<name>=shared for EVERY cluster that needs LoadBalancer Services; a cluster whose name is not on the subnet tag is excluded by the in-tree cloud provider and cannot place an NLB/ELB."

*Grounded in: auto-012 — the spoke ingress NLB never provisioned because the public subnets were tagged only for the mgmt cluster.*

# justification

The mgmt and spoke EKS clusters share one VPC. EKS tags only the subnets in a cluster's own vpcConfig, and the spoke used the private node subnets — so the public `kubernetes.io/role/elb` subnets carried only `kubernetes.io/cluster/k8-platform-mgmt`. The spoke's in-tree AWS cloud provider treats a subnet tagged for a different cluster as ineligible, found zero ELB subnets, and silently never created the ingress NLB: the controller Service sat `Progressing` with no error surfaced to ArgoCD or the app health. The fix is to add `kubernetes.io/cluster/<spoke>=shared` to the shared ELB subnets. Cost of the rule: a few subnet tags at VPC/cluster provisioning; cost of missing it: a silent, hard-to-attribute LoadBalancer hang.
