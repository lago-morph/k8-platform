# agent instruction

**Select Crossplane-built cloud resources by the provider crossplane-kind tag, never by name.** "When a live check must find the real cloud resource a Crossplane abstraction produced, select it by the provider-stamped tag `crossplane-kind=<kind>.<group>` (plus `PlatformAbstraction`), never by resource name. The Upbound provider auto-generates names (an XDatabase RDS instance is named `terraform-<rand>`), so a name match both misses the real resource and can match a Terraform lookalike."

*Grounded in: auto-014 Track A, where the live XDatabase RDS instance was named `terraform-20260608...` yet tagged `crossplane-kind=instance.rds.aws.m.upbound.io`.*

# justification

Every behavioral oracle in the live suite must distinguish "the Crossplane abstraction really produced this" from "a Terraform/manual lookalike exists". The naive instinct is to match on a predictable name, but the Upbound provider sets the cloud identifier itself when no external-name is pinned — producing `terraform-<rand>` for a Crossplane-owned RDS instance. Matching by name would have skipped the real resource (false SKIP → false RED via expect-full) and, worse, could match an unrelated Terraform resource (false PASS). The provider stamps `crossplane-kind`, `crossplane-name`, `ManagedBy=crossplane`, and usually `PlatformAbstraction` on every managed resource; `crossplane-kind` is exact and a Terraform resource never carries it. The cost of the rule is one `list-tags` call per candidate; the cost of ignoring it is a whole class of silently-wrong oracles.
