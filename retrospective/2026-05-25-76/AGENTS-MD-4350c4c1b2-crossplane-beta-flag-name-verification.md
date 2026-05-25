# agent instruction

**Crossplane beta flag names must be verified from source before use.** When disabling a Crossplane feature flag, look up the exact CLI flag name from the Crossplane source (`core.go` or the equivalent for the target version) or the release notes before writing it into `helm.tf` or `run.sh`. Do not guess from the field name in the Crossplane feature-gate struct. The struct field name (`EnableSSAClaims`) does not map predictably to the CLI flag name (`--enable-ssa-claims`), and an unknown flag causes a pod crashloop that triggers helm's 5-minute timeout.

To verify: browse `https://github.com/crossplane/crossplane/blob/v<VERSION>/cmd/crossplane/core.go` and search for the struct field name. The `fs.BoolVar(&o.<Field>, "<flag-name>", ...)` call gives the exact flag.

*Grounded in: PR #74 commit `de6132c` — initial flag `--enable-claim-ssa=false` caused crossplane pod crashloop; correct flag is `--enable-ssa-claims=false` from core.go.*

# justification

The initial attempt at disabling the SSA-claims beta feature used `--enable-claim-ssa=false`, derived by guessing from the struct field name `EnableSSAClaims`. Crossplane rejected it as an unknown flag, the pod entered a crashloop, and helm waited the full 5-minute timeout before failing. The correct flag, found in `core.go`, is `--enable-ssa-claims=false`. This cost approximately 7 minutes per CI run across multiple iterations plus the debugging time to identify the root cause.

The struct-field-to-flag mapping in Crossplane is not mechanical. `EnableSSAClaims` → `--enable-ssa-claims` (not `--enable-claim-ssa`, not `--enable-ssa-claim`). Other flags follow similarly non-obvious patterns. The one reliable source is the `fs.BoolVar` call in `core.go` for the exact target version. Looking it up costs 30 seconds; guessing wrong costs 5 minutes per attempt.
