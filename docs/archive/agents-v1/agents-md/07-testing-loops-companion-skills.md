# 7. Testing loops — companion skills

- After every `git push` to a non-main branch that affects Terraform,
  invoke the **`terraform-ci-watch`** skill.
- After applying a Crossplane Claim, XRD, or Composition (whether via
  `kubectl`, ArgoCD sync, or CI), invoke the
  **`crossplane-claim-verify`** skill to wait for `Synced`/`Ready` and
  verify the underlying cloud resource is healthy.
- When a claim is stuck or slow, run
  `scripts/crossplane-trace.sh <kind>/<name> [-n <ns>]` for a one-shot
  condition walk down claim → XR → managed-resources → IRSA → atProvider;
  use `--watch` while waiting for reconciliation and `--json` to diff
  snapshots across runs.

---

*Source detail for `AGENTS.md`. The summary in AGENTS.md is authoritative for scope; this file holds the full text.*
