# agent instruction

**Keep cluster facts in a per-cluster ConfigMap and workloads cloud-agnostic.** "Cluster-level facts (domain, region, ACM cert ARN, IRSA role ARNs) belong in a per-cluster ConfigMap provided by the cluster abstraction and read by platform add-ons; do NOT thread them through per-application Helm value overlays, and keep workload apps cloud-agnostic (no ARNs/region/provider knowledge) so they neither know nor care which cloud they run on."

*Grounded in: auto-012 — per-app cert-ARN/domain/role-ARN Helm overlays fought bootstrap selfHeal; the user called this out as a smell.*

# justification

auto-012 threaded account-ephemeral AWS facts (ACM cert ARN, domain, external-dns role ARN, region) through per-app Helm `valuesObject` overlays. That caused two distinct problems: bootstrap's selfHeal kept reverting the overlays (they aren't in git, and can't be — they're account-ephemeral), and it leaked AWS-specific identifiers into workloads that should be portable. The user's framing is the durable principle: "an app should not need to know what region it is in, or the ARN of anything — these are kubernetes apps that shouldn't even know they are running on AWS." A per-cluster ConfigMap, owned by the cluster abstraction and read by the add-ons that genuinely need those facts (e.g. external-dns), removes both problems and keeps workloads cloud-agnostic. The marginal cost is one ConfigMap per cluster; the cost of the smell is a recurring selfHeal fight plus non-portable workloads.
