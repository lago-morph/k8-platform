# agent instruction

**Shared parsing constraints across producer and verifier.** When one script produces an artifact from parsed input and another script verifies the artifact against the same input, both scripts must share the parsing constraints (regex column rules, separator handling, escape conventions) — ideally factored into a single helper module, or at minimum reviewed side-by-side at PR time. Independent regexes drift, and the verifier silently passes (or spuriously fails) on inputs the producer handled correctly.

*Grounded in: PR #73's first verifier reported 7 spurious mismatches because its regex used `.+?` for column boundaries while the builder used `[^|]+?`; rows with backticks containing literal `|` characters parsed differently in the two scripts.*

# justification

ADR-bfe703bd53 requires every artifact-producing tool to ship with an independent verifier. This rule adds the necessary fine-print: "independent" means different algorithms / different code paths, NOT different parsing constraints. When producer and verifier disagree about how to parse the same input format, the verifier becomes worse than useless — it generates noise that obscures real bugs.

The PR #73 example is instructive. The builder correctly used `[^|]+?` for short fixed-width columns (id, category, phase) because those should never contain `|`, even inside backtick spans. The verifier used `.+?` for all middle columns — looser, "more permissive". The result: in a row whose justification cell contained `Replaces \`kubectl logs ... | grep\`; survives pod restarts.`, the builder correctly assigned the whole quoted string to justification; the verifier split it across the justification/phase boundary at the first literal `|`. Seven such rows reported as spurious mismatches. The fix was a 10-second regex alignment, but the diagnostic loop to find it took ~10 minutes.

The marginal cost of the rule is small: factor the shared regex into a helper, or paste-and-comment-with-rationale, or at minimum cross-review the two scripts side-by-side. The marginal benefit is large: every drift in parsing rules between producer and verifier is caught at PR-review time rather than at first-run-against-real-data time.
