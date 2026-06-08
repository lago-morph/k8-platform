# agent instruction

**Diagnose a scoped role's exact permission gaps by assuming it from the sandbox before editing its policy.** "When a scoped role may lack permissions, `aws sts assume-role` into it from the sandbox (with any required session tag) and run the real calls to see exactly which are denied, rather than guessing verbs to add. Confirm the additions are both necessary and sufficient by elimination."

*Grounded in: auto-014, where assuming the verifier/reaper role surfaced exactly three DENIED verbs (acm:ListTagsForCertificate, iam:ListRoles, iam:ListRoleTags) while every other call was already allowed.*

# justification

Editing an IAM policy by guessing which verbs a tool needs is slow and error-prone — you either over-grant (defeating a zero-wildcard design) or under-grant (the next run still fails). The cheap, exact alternative is to become the role: the sandbox can assume the scoped verifier/reaper role (its trust permits it with the live-verify session tag) and run the actual checks, watching each call return ALLOWED or DENIED. In auto-014 this turned a hand-wave ("the acm/iam checks probably need more perms") into a precise, three-verb diff that was provably necessary (those calls denied) and sufficient (every other call already allowed). The cost is a single assume-role; the payoff is a minimal, correct, first-try policy change instead of a guess-and-recheck loop through CI.
