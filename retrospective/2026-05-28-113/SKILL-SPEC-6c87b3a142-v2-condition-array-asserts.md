# Spec: `v2-condition-array-asserts`

- **ID**: SKILL-SPEC-6c87b3a142
- **Source retrospective**: ../2026-05-28-113.md

## Intent

Translate any chainsaw `status.conditions:` assert on a Crossplane v2 XR into the full 3-condition shape (Synced + Ready + Responsive) that v2 actually emits. Kyverno-json (chainsaw's match engine) matches arrays element-wise + length-checked, so an assert of `[Ready]` or `[Synced, Ready]` against a 3-condition v2 XR returns `lengths of slices don't match` — even though the XR is healthy. The skill rewrites scenarios to match v2 reality.

## Trigger

Activate when:
- User adds or modifies a chainsaw `status.conditions:` block under `platform.k8-platform.io/v1alpha1` XR kinds (`XPlatformSecret`, `XPlatformCluster`, …).
- A chainsaw run fails with `status.conditions: Invalid value: …: lengths of slices don't match` (this is the load-bearing failure signature).
- User runs `bash tests/unit/test_chainsaw_xr_conditions_complete.sh`.

Do NOT activate for:
- Non-XR `status.conditions:` (e.g., k8s built-in resources like Deployment which have a different condition shape).
- ExternalSecret/ManagedResource/MR conditions — those have their own shapes.

## Inputs

- Working tree of chainsaw scenarios (`tests/chainsaw/**/chainsaw-test.yaml`).
- Optional: the chainsaw failure log (to confirm the symptom matches the v2-condition cause vs. some other length-mismatch issue).

## Outputs

- For each `status.conditions:` block in a v2-XR assert, the file is rewritten to include all 3 conditions in this order: Synced, Ready, Responsive.
- A summary report listing which files were modified and what changed.

## Workflow

1. Discover candidate files: `grep -rln '^[[:space:]]*kind:[[:space:]]*XPlatform' tests/chainsaw/`.
2. For each file:
   a. Parse YAML to locate `status.conditions:` blocks inside `assert.resource.status`.
   b. Check whether the block contains entries for Synced + Ready + Responsive.
   c. If any condition type is missing, append the missing entries with `status: "True"`. Order MUST match Crossplane's output order: Synced, Ready, Responsive.
   d. If the block has conditions in a different order, rewrite to canonical order.
3. Verify with `tests/unit/test_chainsaw_xr_conditions_complete.sh`.
4. Print summary: files modified, conditions added.

## Concrete examples

**Example 1 — v1 scenario imported into v2 repo**:
Original (was correct for v1, wrong for v2):
```yaml
status:
  conditions:
    - type: Ready
      status: "True"
```
After skill:
```yaml
status:
  # v2 XRs have 3 conditions: Synced, Ready, Responsive
  conditions:
    - type: Synced
      status: "True"
    - type: Ready
      status: "True"
    - type: Responsive
      status: "True"
```

**Example 2 — partial v2 assert**:
Original (auto-003 strike 2 state):
```yaml
status:
  conditions:
    - type: Synced
      status: "True"
    - type: Ready
      status: "True"
```
After skill: same shape as Example 1's output.

## Anti-patterns

- **Using JMESPath expressions like `(conditions[?type=='Ready'][0].status): "True"`** to bypass length matching. While that works, it loses the documentation value of listing all 3 conditions explicitly. Future readers don't see the v2 contract.
- **Adding Responsive without Synced first.** Order matters in chainsaw's array match. List in Crossplane-emit order (Synced, Ready, Responsive).
- **Asserting `status: "False"` for Responsive.** Responsive=False indicates the v2 watch circuit is open (provider unreachable). Tests want healthy XRs; assert True.

## Acceptance criteria

1. After the skill runs, every chainsaw `status.conditions:` block on a v2 XR has 3 entries (Synced, Ready, Responsive) all with `status: "True"`.
2. `tests/unit/test_chainsaw_xr_conditions_complete.sh` passes 5/5.
3. The skill is idempotent — running it on already-correct files produces no changes.
4. Comments inserted by the skill identify the v2 contract for future readers.

## Files this skill creates / modifies

- `tests/chainsaw/platform-secret/{00,01,02}/chainsaw-test.yaml` — modified (added Responsive; reordered if needed).
- `tests/chainsaw/platform-cluster/**/chainsaw-test.yaml` — modified if XR conditions are asserted there.
- `tests/unit/test_chainsaw_xr_conditions_complete.sh` — the verifier (already exists, PR #105 commit `8298c1f`).
