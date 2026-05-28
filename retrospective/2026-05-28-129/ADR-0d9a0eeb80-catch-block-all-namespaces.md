# ADR: Chainsaw catch block enumerates XRs across all namespaces, not the per-test scratch namespace

- **ID**: ADR-0d9a0eeb80
- **Status**: Draft (not yet adopted to docs/adr/)
- **Date**: 2026-05-28
- **Source retrospective**: ../2026-05-28-129.md
- **PRs covered**: #128

## Context

The canonical `tests/chainsaw/_lib/catch-block.yaml` (SPEC-A4 enforcer-backed) originally enumerated XRs with `kubectl get $xr_kind -n $NAMESPACE`, where `NAMESPACE` was bound to chainsaw's per-test scratch namespace via `value: ($namespace)`. The design assumption was: chainsaw scenarios apply XRs in `($namespace)`.

That assumption broke in commit 8526f46 (auto-003 PR-T3) — the platform-secret and platform-cluster scenarios deliberately apply XRs to `namespace: default` (literal) to dodge a chainsaw schema-validation rejection of `($namespace)` in `apply.resource.metadata.namespace`. The catch block was never updated. Result: the catch script's `kubectl get $xr_kind -n chainsaw-good-titmouse` returned "No resources found" while the XR actually lived in `default`. The MR-describe loop never ran. Every chainsaw failure produced diagnostically empty catch output.

This was exactly the failure mode that OI-2026-05-28-1 (composition-drift cold-start timeout) needed to diagnose. The catch was blind to the failing XR. The fix had to land before Issue A could be properly investigated.

## Decision

The canonical catch block in `tests/chainsaw/_lib/catch-block.yaml` enumerates XR kinds with `kubectl get -A` and walks their `resourceRefs` from the namespace each XR actually lives in:

```yaml
- script:
    content: |
      set +e
      for xr_kind in xplatformsecret xplatformcluster; do
        kubectl get "$xr_kind" -A \
          -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' \
          | while read -r ns name; do
              [ -z "$name" ] && continue
              kubectl describe "$xr_kind" -n "$ns" "$name" 2>&1 | head -c 1500
              kubectl get "$xr_kind" -n "$ns" "$name" \
                -o jsonpath='{range .spec.resourceRefs[*]}...{end}' \
                | while read -r api kind mrname; do
                    [ -z "$kind" ] && continue
                    kubectl describe "$kind.$api" "$mrname" 2>&1 | head -c 1000
                  done
            done
      done
```

The `describe` and `events` operations at the top and bottom of the catch block still target `($namespace)` — they have legitimate uses for the meta-catch-fires meta-test scenario which lives in the scratch namespace.

## Alternatives considered

- **Move all chainsaw XRs back into `($namespace)`.** Would restore the original catch-block design. Rejected because the `($namespace)` literal hits chainsaw's pre-substitution RFC 1123 validation in `apply.resource.metadata.namespace`. The audit's Check D enforces this — Check D was authored exactly because the workaround (apply to `default`) was the cheaper fix.

- **Hard-code a second namespace lookup (`default` + `$NAMESPACE`).** Would work for the platform-secret scenarios but introduces another assumption that breaks the next time someone adds a scenario applying XRs to a different namespace. `-A` is generic.

- **Use chainsaw's `events` operation to surface the per-test events only.** Doesn't help because chainsaw events are namespaced and the failure root cause is on the MR (cluster-scoped via upbound providers), not on the scratch namespace.

## Consequences

**Easier:** the catch block surfaces the actual failing XR's status regardless of where the scenario put it. The next time OI-2026-05-28-1 Issue A re-surfaces, the asm-secret MR's `status.conditions` and `status.atProvider` will be captured — exactly the data that was missing in the first investigation round.

**Harder:** the catch output may grow if multiple namespaces have XRs (e.g., a future scenario applies to both `default` and a per-test namespace). The output budget (5 KB per failure, enforced by `head -c 1500` per describe + `head -c 1000` per MR describe) absorbs this.

**Trade-off accepted:** the `events` and first `describe` operations still target `($namespace)`. Their value in the meta-catch-fires scenario (which deliberately lives in scratch) is preserved at the cost of a small diagnostic blind spot for `default`-namespace events on real scenarios.

## References

- [`../2026-05-28-129.md`](../2026-05-28-129.md) — the source retrospective.
- [`../../tests/chainsaw/_lib/catch-block.yaml`](../../tests/chainsaw/_lib/catch-block.yaml) — the canonical block.
- [`../../tests/unit/test_chainsaw_catch_block.sh`](../../tests/unit/test_chainsaw_catch_block.sh) — the enforcer (27-test structural-parity gate).
- PRs the decision was made in: #128.
- Commit `8526f46` — the original migration of scenarios to `namespace: default` that broke the catch.
