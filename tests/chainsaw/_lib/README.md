# `tests/chainsaw/_lib/`

Shared YAML fragments included verbatim into chainsaw scenarios.

## `catch-block.yaml`

Canonical `Test.spec.catch` block from SPEC-A4. Every scenario under
`tests/chainsaw/` (except files under `_lib/` itself) MUST paste this
block into its `spec.catch:` list. The only field a scenario may
override is the first `describe.kind` (the XR kind the scenario owns —
default `PlatformSecret`, overridden to e.g. `PlatformCluster` for
scenarios under `tests/chainsaw/platform-cluster/`). All other fields
are structurally compared by `tests/unit/test_chainsaw_catch_block.sh`
and must match exactly.

### Truncation budget

Per spec §5, the block keeps per-failure diagnostic output ≤ 5 KB:

| Operation | Per-resource cap | Why |
|---|---|---|
| `describe` (XR) | `head -c 1500` | XR describe carries the conditions block — 1.5 KB fits 4–6 condition entries with their messages. |
| `describe` (each MR) | `head -c 1000` | Each MR's status conditions are smaller; 1 KB × 3–5 MRs = ~5 KB ceiling. |
| `events` | chainsaw default | Roughly 20 lines × ~150 bytes = ~3 KB; the namespace filter keeps it scenario-scoped. |

A scenario with 1 XR + 3 MRs + ~20 events fits well under 5 KB. The
constants are conservative defaults — tuneable later if a real failure
truncates evidence the agent actually needs (track as a follow-up).

### Enforcement

`tests/unit/test_chainsaw_catch_block.sh` runs in `tests/unit/run.sh`
(which fires on every push via `.github/workflows/unit-tests.yml`). A
new scenario missing the block, or one that mutates any field other
than `describe.kind`, fails the unit test before chainsaw runs.

### Meta-test

`tests/chainsaw/meta-catch-fires/chainsaw-test.yaml` is the live proof
that the catch block fires correctly. Its single step deliberately
fails, and `tests/chainsaw/run.sh` inverts the exit-code expectation
for any scenario whose name begins with `meta-` so the harness reports
PASS when chainsaw exits non-zero AND the catch block produced its
expected stdout markers.
