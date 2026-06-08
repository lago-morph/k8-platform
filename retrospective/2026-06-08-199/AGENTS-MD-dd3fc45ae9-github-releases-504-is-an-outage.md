# agent instruction

**A 504 across multiple unrelated GitHub-releases downloads is an external outage, not a code failure.** "When CI fails on `curl`/`helm` fetches from GitHub releases with 504s across several unrelated downloads (helm charts, binaries), it is a GitHub-releases degradation, not your diff. Re-run the failed jobs once it recovers; do not chase each failure webhook or edit code. Note it in the run summary."

*Grounded in: auto-014, where test_helm_render (external-dns then external-secrets charts) and the kubeconform install all 504'd within minutes — a platform-wide GitHub releases blip unrelated to the diff.*

# justification

During a stacked-PR run, every PR re-runs the full suite, so a transient external outage produces a flood of identical failure webhooks. Reacting to each — re-running into a still-degraded dependency, or worse, editing code to "fix" a download that isn't broken — wastes CI minutes and risks introducing a real bug while chasing a phantom one. The tell is the signature: 504 Gateway Timeout, from GitHub releases, across DIFFERENT unrelated artifacts (a helm chart one run, a binary the next). That pattern is a GitHub-side degradation. The correct, cheap response is to diagnose it once, stop chasing the webhooks, note it in the run summary so the reviewer isn't alarmed, and re-kick the jobs once after recovery. AGENTS.md §6.36's "a red gate is real" carves out exactly this genuine-external-blip case.
