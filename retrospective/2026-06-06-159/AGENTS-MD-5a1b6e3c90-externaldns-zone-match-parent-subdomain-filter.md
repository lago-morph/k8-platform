# agent instruction

When an ExternalDNS instance's `domainFilter` is a **subdomain** of the Route53
hosted zone it must write to (e.g. filter `management.<domain>` /
`platform.<domain>` while the account has only the base `<domain>` zone, with no
delegated subdomain zone), it MUST run with `--aws-zone-match-parent` (chart
`extraArgs: ["--aws-zone-match-parent"]`). Without it ExternalDNS refuses to use a
parent zone to manage subdomain records, matches **zero** hosted zones, and
silently publishes nothing — its log shows `Applying provider record filter for
domains: []` and no records (not even its TXT registry) are created. This applies
to every ExternalDNS instance whose filter was narrowed below the zone apex for
multi-instance disjointness; narrowing the filter without adding this flag is a
silent break. Whenever you narrow an ExternalDNS `domainFilter` to a subdomain,
add `--aws-zone-match-parent` in the same change and gate it with a unit test.

# justification

auto-010 (PR #159, run 27071670054): management apply reached its final step and
failed because `argocd.management.<domain>` was never published — ExternalDNS
matched no zone (`domains: []`, `AWSZoneMatchParent:false`) since its
`management.<domain>` filter is a subdomain of the only (base) zone. The filter
had been narrowed from `var.domain` to `management.<domain>` in auto-008 for
dual-instance TXT-registry safety, but `--aws-zone-match-parent` was not added,
so the break stayed latent until a full fresh bring-up. Adding the flag (hub +
spoke) created the record in ~10s and ArgoCD returned HTTP 200 (run 27072048311).
The spoke instance has the identical subdomain-on-parent-zone shape, so it would
have blocked phase 3 the same way. Guard added to
`test_external_dns_disjoint_filters.sh`.
