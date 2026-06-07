# tests/live — the LIVE behavioral suite

The inverted-skip behavioral suite (FINAL-PLAN §2, §4). Where
`tests/integration/run.sh` exits 0 whenever `FAIL==0` — so an all-skipped run on
a rotated/empty account reads GREEN, the disease this overhaul kills — this suite
treats **all-skipped ⇒ RED**, per profile, and promotes a SKIP of a git-declared
(`expect-full`) kind to a **FAIL**.

It **reuses** `tests/integration/lib/test-lib.sh` (no fork); the inversion lives
only in the orchestrator's tabulation and in `lib/live-lib.sh`'s exit-code
contract (a live `skip()` is exit 2, never the integration lib's silent exit 0).

## Exit-code contract (`lib/live-lib.sh`)

| child exit | meaning |
|---|---|
| `0` | pass — declare verified kinds with `covers <group>/<Kind>` |
| `2` | allowed skip (not-applicable, or git does not declare the kind for this cluster) |
| `3` | expect-full violation (git declares the kind but the real resource is absent) |
| other | FAIL |

Orchestrator exit: `0` clean; `1` a check failed OR **all-skipped/zero-checks**
under the active profile; `3` an expect-full kind was not verified by a pass.

## `LIVE_PROFILE` (which TIERS run) — default `full`

| profile | tiers | when |
|---|---|---|
| `full` (DEFAULT) | `after` + `instantiate` + `negative` | a component under active development |
| `verify-only` | `after` only (read-only) | a proven component on a routine bring-up |
| `off` | none | RED + non-zero unless an audited `disable_all` register entry exists |

`full` being the default is a **tested invariant** (`LIVE_PROFILE_DEFAULT=full` in
`run.sh` is the single committed source the unit test reads). A non-`full` choice
is recorded in `SKIP_REGISTER.yaml` — never a silent reduction.

## `LIVE_MODE` (read-only vs mutating WITHIN the running tiers) — fail-closed

Unset/garbage ⇒ `readonly` (an under-specified invocation degrades to safe, never
to provisioning). `verify-only` implies `readonly`; `verify-only` + `mutating` is
rejected. Only the `instantiate` create-path checks consult `mutating`; the
`after` existence/convergence floor is mode-independent.

## Tier dirs

`checks/after/`, `checks/instantiate/`, `checks/negative/` hold the child checks.
They are populated by the later phases (P2 after-the-fact, P4 instantiate, P5
negatives); until then a real run is correctly RED (verifies nothing ⇒ not green).

## Test seams (hermetic unit suite)

`tests/unit/test_live_orchestrator.sh` drives `run.sh` with stub checks via
`LIVE_CHECKS_ROOT`, `LIVE_EXPECT_FULL`, and `LIVE_SKIP_REGISTER` — no cluster, no
AWS — proving the tabulation, profile/mode logic, expect-full promotion, and the
off-register guard.
