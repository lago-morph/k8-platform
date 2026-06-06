# agent instruction

**Never `producer | grep -q` under `set -o pipefail` when the producer emits more than one line.** "`grep -q` exits on first match and closes the pipe; a still-writing upstream (`yq`, `awk`, `kubectl`) takes SIGPIPE (141), and `pipefail` propagates that 141 as the pipeline status — an intermittent false failure. Capture the producer output to a variable and `grep -q … <<<"$var"` (a here-string has no upstream process to SIGPIPE), or use a `case`/parameter-expansion match."

*Grounded in: 2026-06-05 auto-005 — a ~10% flake in `test_platform_cluster_composition.sh` traced to `yq … | grep -qF` under pipefail.*

# justification

A real ~10% CI flake (`composition_policy_AmazonEKSWorkerNodePolicy`) came from `yq … | grep -qF` under `pipefail`; it red-failed builds intermittently with no code defect, measured at 2-3/20-30 runs. The fix (capture + here-string) removes the whole bug class and was verified at 0/30. The marginal cost is trivial; the cost of the antipattern is non-deterministic CI that erodes trust in every red check and sends future agents chasing phantom regressions.
