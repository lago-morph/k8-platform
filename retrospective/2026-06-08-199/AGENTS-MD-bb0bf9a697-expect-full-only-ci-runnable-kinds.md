# agent instruction

**Broaden a scope-and-grow expect-full set only to kinds runnable under the scoped CI identity, not merely provisioned.** "Before adding a kind to a CI gate's expect-full set, confirm its check passes under the actual CI identity/runner, not just from an admin sandbox: relay/kubectl-based checks SKIP on a runner without those tools, and AWS-describe checks SKIP if the scoped role lacks a read verb. A kind that is provisioned but not CI-runnable would wrongly turn the gate RED."

*Grounded in: auto-014, where SecurityGroupRule + ExternalSecret pass from the sandbox (kubectl relay) but SKIP on the CI runner, and the acm/iam checks needed three scoped read verbs the CI role lacked.*

# justification

"Provisioned and healthy" is necessary but not sufficient for expect-full membership: the gate runs under a specific, restricted identity on a specific runner, and a check that passes from an admin sandbox can still SKIP in CI. Two real traps appeared in one run: relay/kubectl checks (SecurityGroupRule, ExternalSecret) pass from the sandbox but SKIP on a runner with no kubectl, and the acm/iam AWS-describe checks SKIP under the scoped role until three read verbs are added and applied. Either would silently flip the producer RED after a "harmless" expect-full broadening. The rule costs one verification of the check under the real CI conditions; skipping it ships a gate that blocks every PR until someone reverse-engineers why a "provisioned" kind is RED.
