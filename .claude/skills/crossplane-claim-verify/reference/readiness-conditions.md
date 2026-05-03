# Crossplane Readiness Conditions

The vocabulary the skill checks. These conditions appear on Claims, XRs
(composites), and managed resources — same shape, slightly different
semantics per layer.

## `Synced`

Crossplane has read the spec and reconciled it without a render error.

| Status | Reason | Meaning |
|---|---|---|
| `True` | `ReconcileSuccess` | Crossplane is happy with the spec; the resource definition was applied to the API server (or to the cloud). |
| `False` | `ReconcileError` | Crossplane could not turn the spec into managed resources. Almost always a Composition rendering problem — bad function pipeline, missing patch field, type mismatch. Look at `kubectl describe` events on the XR. |
| `False` | `ReconcilePaused` | The resource has the `crossplane.io/paused: "true"` annotation. Intentional; remove the annotation if you want it to reconcile. |

## `Ready`

The underlying resource exists and is healthy.

| Status | Reason | Meaning |
|---|---|---|
| `True` | `Available` | The cloud resource is provisioned and (per the provider's view) usable. **Does not** guarantee cloud-side correctness — always verify out-of-band. |
| `False` | `Creating` | Normal during provisioning. EKS clusters take ~15 min, RDS takes 5–10. Only treat as failure if it persists past the 10-minute Phase 2 cap. |
| `False` | `Deleting` | The resource is being torn down. If unexpected, check for a recent `kubectl delete` on the claim or its XR. |
| `False` | `Unavailable` | Provider thinks the resource is broken. Read the condition `message` for the specific problem (often an AWS-side error like quota or permission). |

## Layer-specific notes

### Claims

A Claim wraps a single XR. The Claim's `Synced=True` only means the XR
was created — it does NOT propagate the XR's `Ready` upward in the older
v1 API. In v2 (Composition Functions) the Ready condition is propagated.

**Practical rule**: don't trust the Claim's conditions alone — always
walk to the XR and the managed resources.

### Composites (XRs)

Both `Synced` and `Ready` aggregate across all composed resources. If any
managed resource is `Ready=False`, the XR is `Ready=False` too (under
default composition behavior).

### Managed resources

`Ready=True` here means the provider has observed the cloud resource and
the observed state matches the desired state. This is closer to truth
than at higher layers — but still not a substitute for `aws describe-*`.

## Reading conditions in one shot

```sh
kubectl get <kind>/<name> -n <ns> -o json | jq -r '
  .status.conditions[] |
  "\(.type)=\(.status) reason=\(.reason) (\(.lastTransitionTime))\n  \(.message // "")"
'
```

This format is what to paste into the escalation template — it includes
the `message` which is where Crossplane stuffs the actual error.
