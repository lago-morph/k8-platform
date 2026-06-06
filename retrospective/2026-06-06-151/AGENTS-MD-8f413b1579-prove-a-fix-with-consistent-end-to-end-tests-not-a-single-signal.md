# agent instruction

**Prove a fix with consistent end-to-end tests, not a single signal.** "Do not call something fixed or working from one positive observation. Require the real end-to-end operation to succeed repeatedly with the actual tool — a lone 200 or one green check is not proof. State explicitly what was tested vs assumed; if the next call contradicts the first, the state is not-confirmed, not fixed."

*Grounded in: 2026-06-06 — agent declared ArgoCD "reachable / fixed" off one healthz 200; the very next `argocd login` failed on DNS.*

# justification

The agent saw one `curl …/healthz` return 200 and announced "the sandbox can finally reach ArgoCD — the cert fix works." The very next command, `argocd login`, failed with `no such host`: DNS had not propagated and the NLB was still provisioning. The user caught it immediately — "How do you know it is fixed without testing it? You are presenting guesses as fact." A single positive signal is the classic false-confirm: it samples one moment, one resolver, one tool. The fix is cheap — repeat the real operation a few times and run the actual end-to-end action (here, `argocd login`, not just `curl`) before claiming success, and label tested-vs-assumed explicitly. The cost of skipping it is a confident false claim that the user then has to disprove, which is far more expensive than the extra three calls.
