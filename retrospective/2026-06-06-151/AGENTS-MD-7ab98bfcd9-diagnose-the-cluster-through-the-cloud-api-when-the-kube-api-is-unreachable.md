# agent instruction

**Diagnose the cluster through the cloud API when the kube-API is unreachable.** "When kubectl is blocked, do not declare the problem un-diagnosable — reach the same facts through the cloud provider API: pod density via ENI/IP counts, load via CloudWatch, capacity via describe-instance-types, cluster/nodegroup health via the EKS API."

*Grounded in: 2026-06-06 — pod-IP exhaustion (3/3 ENIs, 18/18 IPs on t3.medium) diagnosed entirely via AWS CLI because the EKS kube-API was gateway-blocked.*

# justification

An ingress-nginx admission-webhook hook kept timing out, and the obvious diagnostic — `kubectl describe node` / `get pods` — was unavailable (the EKS kube-API is unreachable from the sandbox; see the egress-gateway rule). The agent's first instinct was to call it un-diagnosable and propose disabling the webhook. The user pushed back ("use the aws cli to get K8s node status"), and the AWS CLI delivered the root cause without the kube-API: idle CPU via CloudWatch, then `aws ec2 describe-network-interfaces` showing both nodes pinned at 3/3 ENIs and 18/18 IPs — the t3.medium max-pods (~17) ceiling, so a new hook-Job pod could not get an IP. That single AWS-side fact converted a guessed "just disable it" into a correct fix (more nodes + prefix delegation). The lesson: a blocked kube-API blocks one *path*, not the *facts* — most cluster-health questions have a provider-API equivalent, and reaching for it beats both guessing and giving up.
