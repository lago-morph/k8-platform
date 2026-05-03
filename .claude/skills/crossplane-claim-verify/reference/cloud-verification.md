# Cloud Verification

Per-XRD-kind recipes for confirming that the actual cloud resource exists
and matches the claim's intent. **Add a recipe whenever a new XRD lands.**

`Ready=True` from Crossplane means "the provider observed it as healthy."
That is necessary but not sufficient — the provider's last-observed state
can lag, and provider bugs do happen. Always do an out-of-band check
before declaring success.

## Template for a new entry

```
### <XRD kind>

**Claim spec fields that should be visible cloud-side:**
- <field> → <where it shows up in the cloud API>

**Verification commands:**
```sh
# command 1
# command 2
```

**Expected output / pass criteria:**
- <one bullet per assertion>

**Common drift modes:**
- <field> may be observed-stale for up to <N>s after creation
```

## Recipes

### `PlatformSecret` (planned for Iteration 2)

Pending implementation in Phase 6 of the plan. Skeleton:

**Claim spec fields:**
- `secretRef` (ASM ARN) → ASM secret payload
- `targetSecretName` → in-cluster `Secret` name in the claim's namespace

**Verification:**
```sh
# Cluster side
kubectl get secret <targetSecretName> -n <claim-namespace> \
  -o jsonpath='{.data}' | jq 'map_values(@base64d)'

# Cloud side
aws secretsmanager get-secret-value \
  --secret-id <secretRef> \
  --query SecretString --output text
```

**Pass criteria:** the two payloads are byte-identical (or, for
JSON-shaped secrets, semantically identical).

**Drift modes:** ESO refresh interval (default 1h) — newly rotated values
won't appear in-cluster until the next refresh unless ESO is configured
with a faster interval.

### `PlatformCluster` (planned for Iteration 2)

Pending implementation in Phase 6 of the plan. Skeleton:

**Claim spec fields:**
- `name` → EKS cluster name
- `region` → AWS region the cluster lives in
- `nodeCount` / `nodeType` → managed node group size and instance type

**Verification:**
```sh
aws eks describe-cluster --name <name> --region <region> \
  --query 'cluster.{status: status, version: version, endpoint: endpoint}'

aws eks describe-nodegroup --cluster-name <name> --nodegroup-name <ng> \
  --query 'nodegroup.{status: status, instanceTypes: instanceTypes, scaling: scalingConfig}'
```

**Pass criteria:**
- `cluster.status == "ACTIVE"`
- `nodegroup.status == "ACTIVE"`
- `instanceTypes` contains the requested type
- `scalingConfig.desiredSize` matches `nodeCount`

**Also verify ArgoCD registration:**
```sh
kubectl get secret -n argocd -l argocd.argoproj.io/secret-type=cluster \
  -o jsonpath='{.items[*].metadata.name}'
```

The new cluster's secret should appear within ~60s of `Ready=True`.

**Drift modes:** EKS reports `ACTIVE` ~30s before the API endpoint is
actually reachable. If `kubectl get nodes` against the new cluster fails
immediately after `Ready=True`, retry once after 30s before treating as
failure.
