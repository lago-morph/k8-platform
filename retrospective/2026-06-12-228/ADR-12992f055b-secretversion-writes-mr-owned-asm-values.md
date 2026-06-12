# ADR: Crossplane-native SecretVersion writes values into MR-owned ASM containers

- **ID**: ADR-12992f055b
- **Status**: Draft (not yet adopted to docs/decisions/; the implementing change is quarantined in OI-2026-06-12-1 pending the chainsaw-environment diagnosis)
- **Date**: 2026-06-12
- **Source retrospective**: ../2026-06-12-228.md
- **PRs covered**: #227 (commits `0ce9f41` → `a95ee41` → `bdcc56a`, since reverted; the design survives as the recorded rework plan)

## Context

The XPlatformSecret abstraction provisions an AWS Secrets Manager *container* as a crossplane managed resource (tagged `ManagedBy=crossplane`, `PlatformAbstraction=PlatformSecret` — the tags the live behavioral check selects on), but historically left the *value* to an out-of-band write — a manual step the SUBSTRATE definition of done bans, and the reason the `secretsmanager Secret` kind could never pass `live-verify.yml` (the check requires an AWSCURRENT version). Closing that gap requires the platform itself to write generated material into a container the MR owns.

The first design used an ESO PushSecret as the value writer, ordering-gated behind the container's ARN (a Required patch) so ESO could never create the remote name first. It deadlocked in two distinct ways on the real-AWS chainsaw suite: ESO's SecretsManager PushSecret refuses to write into an existing secret that lacks its `managed-by=external-secrets` ownership tag (verified against the v0.9.13 provider source: the `isManagedByESO` check raises "secret not managed by external-secrets"), and the ARN gate serialized MR-create → composite-status → push-render into extra reconcile round-trips stacked on the provider's known slow first-create (OI-2026-05-28-1), blowing scenario Ready bounds (chainsaw runs 27385091105, 27387201992).

## Decision

When a Composition must place generated material into an ASM container it owns as a managed resource, compose a `secretsmanager.aws.m.upbound.io` **SecretVersion** MR as the value writer — never an ESO PushSecret.

The composed shape: a Password generator (readiness `None` — generators carry no status conditions) → a generate-once source ExternalSecret (`refreshInterval "0"`, Retain) whose template renders the whole payload as one JSON document under a single key → the SecretVersion with `secretId` set to the container's deterministic name and `secretStringSecretRef` pointing at the source Secret in the MR's own namespace. No ordering gate is needed: the SecretVersion simply retries `PutSecretValue` until both the container and the source Secret exist — parallel convergence.

## Alternatives considered

- **ESO PushSecret, ARN-gated** (built first): rejected on the ownership check plus the gating round-trips above. The failure was proven live, not theorized.
- **ESO PushSecret with the `managed-by=external-secrets` tag composed onto the container** (built second): mechanically unblocks the ownership check, but asserts an ownership that is false — crossplane, not ESO, owns the container — and keeps the gating latency. Rejected as papering over a lie; reverted within one cycle.
- **Let the PushSecret create the container and have the MR adopt it**: impossible — the upjet external-name for an ASM secret is its ARN, unknowable pre-create, so the MR's create fails `ResourceExists` forever. This impossibility is *why* the gate existed in design one.
- **No in-platform material (status quo)**: keeps the manual out-of-band write, permanently blocks the live-verify producer, and leaves the deterministic-naming need (committed cross-cluster consumers) unmet. Rejected — it is the problem.

## Consequences

- Easier: convergence is gate-free and order-independent; no ESO ownership semantics on a crossplane-owned resource; IAM stays within the existing `SecretsManager` Sid plus `secretsmanager:UpdateSecretVersionStage` (the version-retire path).
- Harder / accepted: one more composed MR per XPlatformSecret (five total); the payload must round-trip as a JSON document so the consumer ExternalSecret's `dataFrom` extract still sees a map; rotation is deliberately out of scope (generate-once) — a future rotation story must replace the source ES, not the writer.
- Open dependency: the implementing commits are reverted pending OI-2026-06-12-1 — the chainsaw environment failed *content-independently* (the long-proven composition failed identically at full bounds, run 27392834302), so this design is unvalidated by the gate through no fault of its own. The catch-block namespaced-MR fix is the prerequisite for the decisive run.

## References

- [`../2026-06-12-228.md`](../2026-06-12-228.md) — the source retrospective (Phase 4).
- `docs/open-issues.md` → OI-2026-06-12-1 — the quarantine record carrying the full exclusion trail and the reverted commit ids.
- PR #227 commits `0ce9f41`, `a95ee41`, `bdcc56a` (the three designs) and `614edc3`/`353843c`/`667e8ba` (the reverts).
- external-secrets v0.9.13 `pkg/provider/aws/secretsmanager/secretsmanager.go` — the `managed-by` / `external-secrets` ownership constants and the unmanaged-secret error.
- Related: `docs/decisions/0005-…` (ESO for secret movement/generation — this ADR carves out the MR-owned-container value-write case), `docs/decisions/0011-…` (composite-routed references — the same composite-routing idiom carries the container name into the SecretVersion).
