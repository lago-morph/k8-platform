# 30 — Review of SEG-4 plan (R1B, correctness)

**Reviewer angle:** correctness
**Target:** `20-plan-SEG-4-tooling-regen.md`
**Verdict:** **REVISE-MAJOR**

## Verified upstream URL pattern

`HEAD https://raw.githubusercontent.com/crossplane-contrib/provider-upjet-aws/v2.5.0/package/crds/secretsmanager.aws.m.upbound.io_secrets.yaml` → **200**, `spec.group: secretsmanager.aws.m.upbound.io`, `scope: Namespaced`.

The legacy filename `secretsmanager.aws.upbound.io_secrets.yaml` ALSO returns 200 at v2.5.0 (`scope: Cluster`) — v2 ships BOTH groups for back-compat. The plan's `.upbound.io_` → `.m.upbound.io_` filename substitution is **correct**, but it must also remove the legacy URLs from `CRD_URLS`, otherwise the regenerated store will contain both v1 and v2 schemas — exactly the "transition store" the plan §3.5 says we must avoid.

## Top flaws

### F1 — `v2.5.4` tag does not exist (BLOCKER)

Latest tag on `crossplane-contrib/provider-upjet-aws` is **v2.5.0** (Mar 2026). 00-situation.md §5 and the plan both pin `v2.5.4`. `curl https://github.com/.../tree/v2.5.4` → 404. Step 1 of PR-T1 will hard-fail on the very first `curl`. Fix: bump pins to v2.5.0 (or whatever PR #98 actually resolves) across situation doc, plan, and `versions.env`.

### F2 — fixture regen scope is incomplete

Plan §1 lists 6 trace JSON fixtures, but `tests/unit/fixtures/crossplane-trace/` contains **14** files. The unlisted ones (`claim-failing.json`, `claim-ok.json`, `provider-pkg.json`, `provider-pod-*.json`, `provider-sa-*.json`, `xr-empty-conditions.json`) — at least `claim-*.json` and `xr-empty-conditions.json` plausibly carry `spec.resourceRef`/apiVersion that v2 changes. Plan must audit all 14 or justify the exclusion.

### F3 — render-fixture XR namespace not addressed concretely

Plan §2.2 says "add `metadata.namespace: default` if SEG-1 namespaces the XR" — but per 00-situation §4 the v2 namespaced-XR model is **certain**, not conditional. The plan should commit to the namespace edit and define which namespace (`default`? a dedicated test ns?), not punt.

### F4 — schema-store layout assumption is fragile

`test_kubeconform_manifests.sh` line 44 hard-codes `SCHEMA_LOCATION=kubeconform-schemas/{{ .Group }}/...`. Since `spec.group` IS `secretsmanager.aws.m.upbound.io` (verified), the directory will auto-regen correctly under the new group — but the plan never states a regen command. Missing: `STORE_DIR=kubeconform-schemas rm -rf kubeconform-schemas/*.aws.upbound.io && ./scripts/fetch-crds-for-kubeconform.sh` (concrete invocation).

### F5 — Bug at L215 confirmed real

`scripts/crossplane-trace.sh:215` case glob `*.aws.upbound.io` does NOT match `secretsmanager.aws.m.upbound.io` because the glob's `.` is literal, but more importantly the trailing `.aws.upbound.io` segment isn't a suffix of `.aws.m.upbound.io`. Plan's proposed fix is correct.

### Minor

- §2.2 "fetcher XRD-reader fix" drops the `claimNames` branch — good, but the plan should keep the script tolerant of `claimNames` being absent rather than removing the field read entirely (defensive against mixed-version XRDs).
- Plan omits removing v1 URLs from `CRD_URLS` explicitly (see verification above).

## Recommendation

Fix F1 (version pin) and F2 (fixture inventory) before executing. F3/F4 are clarifications. F5 already in plan. Re-review after revisions.
