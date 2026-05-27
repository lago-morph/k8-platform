# agent instruction

**Read the failure log first.** "When ANY CI check fails, the first action is to fetch the job log (e.g., via `ext-github`'s `download_job_logs` operation, job ID = last path segment of the check's `details_url`). Do not read the PR description, workflow YAML, spec, test source, or commit message before reading the log. Hypotheses formed from indirect sources are guesses; the actual error is in the workflow stdout."

*Grounded in: session 2026-05-26 Phase 2 — multiple turns speculating about AWS-side root causes for chainsaw failures when the log immediately revealed the v1/v2 provider mismatch.*

# justification

This rule already exists in the repo at `ai/testing-guidelines.md §10` (added by PR #96 this session). The promotion to `AGENTS.md` is justified because `testing-guidelines.md` is read situationally ("when working on phase N") whereas `AGENTS.md` is read first thing in every session. The failure-log-first rule applies to every CI failure regardless of phase context, so it deserves higher-up placement.

Quantified cost of not following the rule on the session that codified it: I burned approximately five conversation turns plus three web searches plus two hypothesis-dispatch subagents speculating about AWS-side causes (region mismatch, IAM permissions, eventual consistency, Secrets Manager 7-day recovery, ProviderConfig misconfiguration). The user had to interrupt twice — once to redirect ("are you sure you're using chainsaw properly?"), once to demand the rule itself be written down. The log was a single API call (~10 seconds) and immediately revealed that ESO was successfully fetching the same secrets the Crossplane provider's Observe couldn't see — that asymmetric signature pointed straight at the provider version mismatch as the root cause.

The asymmetry is roughly 100× wasted-vs-avoided work. The marginal cost of the rule is one API call at the start of any CI-debug task. The signature of an active failure log shows up in the first ten lines of the dump for almost every kind of CI red.
