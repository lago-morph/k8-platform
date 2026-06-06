# agent instruction

**Re-run the SHA-matched heavy-CI verifier after any push that lands on top of a green heavy run.** "When a heavy workflow (chainsaw, terraform-test) is dispatch-verified by a push-triggered checker that matches the run head_sha (AGENTS 6.7), do not push further commits — even docs-only — after the green heavy run without either re-dispatching the heavy run on the new HEAD or re-running the verifier. The verifier gates on a green run whose head_sha equals the PR HEAD; a commit on top moves HEAD past the cached green SHA and the verifier reds even though the code is unchanged."

*Grounded in: auto-010 chainsaw-verify red on docs commit e41c5ad after chainsaw passed on fab6026.*

# justification

After the chainsaw run went green on commit fab6026, a docs-only handoff commit
(e41c5ad) was pushed on top. The push-triggered chainsaw-verify check gates on a
green chainsaw run whose head_sha equals the PR HEAD; HEAD was now e41c5ad while
the green run was on fab6026, so chainsaw-verify reded despite the code being
byte-identical. The fix is one of: dispatch the heavy run against the new HEAD,
re-run the verifier job, or order the docs commit before the heavy dispatch. The
asymmetry is stark — a single misordered docs push produced a red required check
at merge time; the remedy is a single re-run.
