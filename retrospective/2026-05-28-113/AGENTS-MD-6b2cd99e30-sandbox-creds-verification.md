# agent instruction

**When the sandbox lacks `aws` CLI, verify rotated AWS creds via `terraform-test phase=base apply-and-verify` outcome, NOT via local `aws sts get-caller-identity`.** "AGENTS.md §8.1 / §8.2 say to verify creds at session start. If `aws` CLI is not on PATH in the sandbox (a structural absence, not a creds-stale situation), the local verification path fails for the wrong reason. Adapt the verification by dispatching `terraform-test phase=base apply-and-verify` against `main` as the first action; the workflow's `Verify AWS CLI` + `Bootstrap state backend` steps are the equivalent verification path running on the GitHub Actions runner (which DOES have the CLI). The exit shape tells you whether rotation took: SUCCESS = creds work; `InvalidClientTokenId` / `403` in the log = creds didn't take. Document the adaptation in the run-summary so future sessions don't re-invent it."

*Grounded in: auto-003 Step 1 — sandbox's `bash scripts/whereami.sh --json` returned `ERROR: AWS credentials are absent or invalid (aws sts get-caller-identity failed)` because `which aws` was empty, not because rotation failed. Workflow run 26543008528 then confirmed creds work by reaching `Verify AWS CLI` GREEN.*

# justification

This adaptation cost ~3 minutes to figure out in auto-003 (the lead agent had to introspect `whereami.sh`, find that it sources `_lib/aws-cli-helpers.sh`, and realize the `aws` CLI binary itself was absent). With the rule codified, the next session knows immediately to use CI dispatch as the verification gate. Cost of adopting: one paragraph in AGENTS.md. Cost of NOT adopting: 3-5 minutes of confused diagnostic per session, plus the risk of misclassifying a structural sandbox absence as a creds-rotation failure (and stopping the run unnecessarily).
