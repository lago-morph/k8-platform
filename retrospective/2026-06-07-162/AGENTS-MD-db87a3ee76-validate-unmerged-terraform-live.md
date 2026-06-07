# agent instruction

**Validate unmerged Terraform against the live account before merging.** "For terraform that can't be validated locally (the sandbox has no terraform binary), dispatch `terraform-test` `plan` on the FEATURE-BRANCH ref first to validate it without mutating, then `apply-and-verify` on the same ref, and merge only once the live apply is green. Never merge terraform to `main` that hasn't been proven against the live account — `main` must never describe infra that has not successfully applied."

*Grounded in: auto-011 — the management plan on the branch ref validated the subagent's unmerged envconfig/provider-kubernetes terraform; apply-and-verify then surfaced the provider-kubernetes 404; #162 was merged only after a green apply.*

# justification

The sandbox has no terraform binary, so CI against the live account is the only validation path. Running `terraform-test plan` on the branch ref first confirmed the subagent's unvalidated `.tf` (EnvironmentConfig extension + provider-kubernetes) parsed and planned cleanly (5 add / 4 terraform_data replace / 0 real-infra change) before any mutation; the subsequent `apply-and-verify` caught the bad package tag at install time. Had the PR been merged first, `main` would have carried terraform that never applied and the handoff would have described a cluster state that didn't exist. The plan→apply→merge order costs two CI dispatches and keeps `main` an honest mirror of the live account.
