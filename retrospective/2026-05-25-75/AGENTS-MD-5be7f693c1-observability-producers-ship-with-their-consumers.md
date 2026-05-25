# agent instruction

**Observability producers ship with their consumers.** When adding a producer of observability data (CloudWatch log group, metric filter, CloudTrail trail, VPC flow log, alarm), the same PR must add the consumer that automatically reads it from a code path agents already walk — a saved Logs Insights query named in Terraform, a `scripts/diagnose/*.sh` helper invoked by an existing skill, a metric surfaced in an already-mandated status script, or evidence auto-attached on test failure. A producer without a consumer is storage cost with no realized benefit — future agents will not remember to check the new data source during a debug loop.

*Grounded in: the top-15 immediate-changes review (PR #75), where items #3 / #4 / #5 (EKS logging / VPC flow / CloudTrail) failed the "what makes a future agent actually use this?" test until paired with consumer scripts.*

# justification

The user's pushback during PR #75 named this directly: *"instructing an agent to do anything is extremely fragile. For the ones that set up logging and monitoring, what tells a future agent to actually use those capabilities?"* The retros confirm the failure mode quantitatively: PRs #66/#67/#68 each burned 30-60 minutes walking IRSA chains that CloudTrail had already recorded; phase-2-diagnose.yml was authored ad-hoc because no one remembered the existing audit log group had the answer; the "Apply complete: 0 added" silent no-op (PR #67) was caught by a human noticing the count, not by any documented checking discipline.

The marginal cost of the rule is small: one additional artifact (a `aws_cloudwatch_query_definition`, a `scripts/diagnose/*.sh` helper, a metric-filter consumer) shipped in the same PR. The marginal benefit is large: every observability investment is realized, not just stored. Producing data and telling an agent to look at it is the same as not producing it — only the data that auto-flows into an existing agent habit gets consulted.
