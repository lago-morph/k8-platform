# Spec: `cloud-api-cluster-diagnostics`

- **ID**: SKILL-SPEC-a19fabe614
- **Source retrospective**: ../2026-06-06-151.md

## Intent

When `kubectl` is unavailable — a private-CA kube-API behind a verifying egress proxy, no in-cluster credentials, or a CI-only API — recover the cluster facts you need from the **cloud provider's API** instead of declaring the problem un-diagnosable. This session lost time treating a blocked kube-API as a dead end (the first instinct was to disable a failing webhook blindly); the AWS CLI then produced the exact root cause — pod-IP exhaustion — without ever touching the kube-API. The skill encodes the mapping from "what I'd `kubectl` for" to "the provider-API call that answers it," so diagnosis continues from a sandbox that cannot reach the cluster.

## Trigger

- Direct: "diagnose the cluster without kubectl", "kube-API is blocked, what's wrong with the nodes", "use the cloud API to check node/pod status".
- Proactive: any time a `kubectl`/`argocd`-resource call returns a TLS/connect error (`unable to get local issuer certificate`, `no such host`, 503 from a proxy) AND you need a cluster-health fact to proceed.
- Negative: skip when `kubectl` works (just use it) or when the question is purely application-level state with no cloud-API projection (e.g. a ConfigMap's contents).

## Inputs

- Cloud + cluster identifiers: provider (AWS), region, cluster name, node group name.
- Working cloud credentials (e.g. a sourced `awsenv`), verified with `aws sts get-caller-identity`.
- The specific question to answer (node count/health, pod density, resource pressure, addon/version state).

## Outputs

- A concise diagnosis with the provider-API evidence inline (the commands + their output), labelled as cloud-API-derived (not kube-API) so confidence is auditable.
- No mutations — this skill is read-only.

## Workflow

1. Confirm `kubectl` really is blocked (one attempt) and creds work (`aws sts get-caller-identity`). Note the block reason.
2. Translate the question via the map below and run the matching read-only calls:
   - **Node count / health / scaling** → `aws eks describe-nodegroup --query 'nodegroup.{status,health,scalingConfig}'`; backing instances via the ASG → `aws ec2 describe-instances`.
   - **Pod density / "can a new pod schedule"** → ENI/IP saturation: `aws ec2 describe-network-interfaces --filters Name=attachment.instance-id,Values=<id>` and count `PrivateIpAddresses`; compare to `aws ec2 describe-instance-types --query 'InstanceTypes[0].NetworkInfo'` and the VPC-CNI max-pods formula `(ENIs*(IPv4perENI-1))+2`.
   - **CPU/load** → `aws cloudwatch get-metric-statistics --namespace AWS/EC2 --metric-name CPUUtilization`. **Memory utilization** is only available if Container Insights / the CW agent is installed (`aws cloudwatch list-metrics --namespace ContainerInsights|CWAgent`); if absent, say so — don't infer memory from nothing.
   - **Addon / version state** → `aws eks list-addons` / `describe-addon`; cluster version via `describe-cluster`.
3. State the conclusion with the evidence, and explicitly flag any fact the cloud API *cannot* give (e.g. exact per-node pod counts, pod scheduling-reason events — those need the kube-API via CI). Distinguish "warm-pool IPs allocated" from "pods running" (the CNI pre-allocates).
4. Recommend the fix that the cloud-API evidence supports; if a fact is only obtainable via kube-API, route that part through CI rather than guessing.

## Concrete examples

**Example 1 — ingress hook won't schedule (this session).** Question: why does the ingress-nginx `kube-webhook-certgen` Job time out? `kubectl` blocked. CloudWatch showed both t3.medium nodes at 5-7% CPU (not load). `aws ec2 describe-network-interfaces` showed each node at **3 ENIs / 18 IPs** = the t3.medium maximum; `describe-instance-types` confirmed `MaximumNetworkInterfaces=3, Ipv4AddressesPerInterface=6` → max-pods ≈ 17. Conclusion: pod-IP exhaustion, the hook Job can't get an IP. Fix: add a node + prefix delegation. Caveat flagged: 18 IPs allocated is an upper bound on pods (CNI warm pool); exact pod count needs the kube-API.

**Example 2 — is the new node up before I re-apply?** Question: did the node group reach the new desired count? `aws eks describe-nodegroup --query 'nodegroup.{status:status,scaling:scalingConfig}'` → `status=ACTIVE, desiredSize=3`. Conclusion: safe to re-run the Terraform apply (the EKS managed-nodegroup update is complete), without any kube-API call.

## Anti-patterns

- Declaring "un-diagnosable, let me just disable the failing thing" when a provider-API equivalent exists (this session's original, wrong instinct).
- Reporting allocated ENI IPs as "pods running" — the VPC-CNI keeps a warm pool, so allocated ≥ running.
- Inferring memory pressure when no Container Insights/CWAgent metrics exist — say the data is unavailable instead.
- Presenting a cloud-API inference as a kube-API fact; label the source so the next reader knows what was actually observed.

## Acceptance criteria

1. Given a blocked kube-API and a node-health question, the skill returns a conclusion backed by ≥1 concrete provider-API command + output.
2. It correctly distinguishes facts the cloud API can vs cannot provide, routing the latter to CI.
3. It never mutates state.
4. Its pod-density verdict cites the ENI/IP count and the instance-type max-pods, with the warm-pool caveat.
5. A fresh-context agent can run it from this file alone.

## Files this skill creates / modifies

- None (read-only diagnostic). Output is the chat diagnosis; optionally append durable findings to `docs/open-issues.md` only if a genuinely *undiagnosed* problem remains.
