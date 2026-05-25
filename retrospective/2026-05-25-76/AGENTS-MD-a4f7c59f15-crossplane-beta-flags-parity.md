# agent instruction

**Crossplane beta flags must be identical in management and chainsaw.** When adding or changing `--enable-X=false` feature-flag args for a Crossplane version bump, apply the identical set of args in BOTH `terraform/management/helm.tf` (live EKS cluster) AND `tests/chainsaw/run.sh` (kind cluster). Drift between the two silently invalidates chainsaw as a proxy for production: scenarios pass on kind because a beta feature is active there but disabled on EKS (or vice versa), producing false-green CI against a configuration that fails on the live cluster.

*Grounded in: PR #74 — three beta flags added simultaneously to helm.tf and run.sh to enforce parity after the 2.3.0 upgrade.*

# justification

The chainsaw harness exists to be a fast, cheap proxy for production Crossplane behavior. That proxy is only valid if kind and EKS run identical Crossplane configurations. Feature flags are part of that configuration. During the 2.3.0 upgrade, three beta features were disabled: `--enable-realtime-compositions=false`, `--enable-ssa-claims=false`, `--enable-custom-to-managed-resource-conversion=false`. Had they been added only to helm.tf and not run.sh, every chainsaw run would have tested a Crossplane with those features ON while the live cluster had them OFF — or vice versa after a helm.tf-only change. A false-green chainsaw run in that state would send a broken upgrade to production.

The existing unit test `test_chainsaw_crossplane_matches_management.sh` already enforces chart version parity between the two files. Feature flag parity is the same invariant and deserves the same discipline. The marginal cost: one grep of run.sh when editing helm.tf.
