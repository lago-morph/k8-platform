# ADR: Account-ephemeral realm identity config via import-time env substitution

- **ID**: ADR-739c51a2ad
- **Status**: Draft (not yet adopted to docs/adr/)
- **Date**: 2026-07-06
- **Source retrospective**: ../2026-07-06-255.md
- **PRs covered**: #255

## Context

The Keycloak `platform` realm import needs eight account-ephemeral values
(Cognito endpoints + confidential client) that must never be committed
(AGENTS: account-specific values flow through discovery). Clean build #3
had already proven the failure mode of half-measures: placeholder URLS in
the realm JSON fail Keycloak's import-time validation and CrashLoop the
StatefulSet (defect #233), which is why the broker block was removed
outright rather than placeholdered. Re-landing it required a mechanism
where the realm text stays committed and generic while the values arrive
real — and where "values missing" is a state the import can never
observe. The web record on Keycloak's env substitution was contradictory
(official docs say `${VAR}` works; issues #20199/#12069 report it broken
or fixed at various versions), so PR #255 settled it empirically against
the pinned 24.0.5 image in docker before building anything.

## Decision

The Keycloak realm import carries account-ephemeral values as `${VAR}`
env placeholders substituted at `--import-realm` from **non-optional**
secretKeyRef container env (sourced from an ESO-materialized Secret),
making unresolved-placeholder states unreachable: the pod cannot start
until the Secret and every referenced key exist.

## Alternatives considered

- **Helm-template the realm via the ApplicationSet's valuesObject
  (cluster-facts, ADR-0010)**: rejected — the realm ConfigMap rides the
  ApplicationSet's raw directory source (no templating), and the client
  SECRET can never travel valuesObject (it is committed template text +
  annotations, not secret material). Env substitution handles secret and
  non-secret values through one mechanism.
- **keycloak-config-cli as a reconciling importer**: rejected for now —
  a new component and operational surface to adopt for what is, on an
  intentionally-ephemeral platform, a rebuild-converged concern; noted
  as the natural home if realm-config drift management ever becomes a
  requirement.
- **Optional secretKeyRefs (pod starts, values maybe absent)**: rejected
  — probed empirically: an UNSET placeholder survives import verbatim
  and then fails URL validation = exactly the #233 CrashLoop, but
  nondeterministically (a race between ESO and the StatefulSet).
  Non-optional refs convert the race into a clean Pending state.

## Consequences

- Easier: the committed realm is byte-stable across accounts; the same
  probe pattern (docker + pinned image + representative env) validates
  any future realm change locally in ~2 minutes; the `${CLAIM.email}`
  Keycloak-mapper dialect coexists safely because unset placeholders
  pass through untouched (probed, not assumed).
- Harder / accepted: **realm changes only converge on a fresh Keycloak
  database** — startup import runs strategy IGNORE_EXISTING, so a live
  realm never re-imports; on this platform that means "at the next
  account rotation / clean build", documented in the realm CM header and
  the SUBSTRATE rows-10/11 evidence policy (build #6 is the earliest
  honest flip). The env contract spans four files (terraform keys → ES
  extract → ApplicationSet env refs → realm placeholders) and is held
  together by `test_keycloak_cognito_idp_contract.sh` (52 assertions);
  without that pin, drift in any file silently breaks first boot on the
  next fresh build.
- The ApplicationSet is the single home for keycloak `extraEnvVars`
  (helm valuesObject LISTS REPLACE valueFiles lists) — future env
  additions must land there, per the extended comment in
  `argocd/apps/spoke/keycloak.yaml`.

## References

- [`../2026-07-06-255.md`](../2026-07-06-255.md) — the source retrospective (Phase 3; the three docker probes).
- [`./ADR-9766770001-terraform-writes-external-federation-material-to-asm.md`](./ADR-9766770001-terraform-writes-external-federation-material-to-asm.md) — where the substituted values come from.
- `platform-services/keycloak/spoke/realm-platform-configmap.yaml` — the mechanism's in-tree documentation (header) + the broker block itself (PR #255).
- `tests/unit/test_keycloak_cognito_idp_contract.sh`, `tests/unit/test_keycloak_realm_json.sh` — the mechanical pins.
