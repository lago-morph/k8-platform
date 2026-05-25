# SPEC-LA8 — `scripts/r53-watch.sh <name>` — authoritative Route53 propagation watch

Brainstorm ID: **A1-031** · Tier: **A** · Estimated effort: **S**

## 1. Summary

Add `scripts/r53-watch.sh <name>` — a single Bash script that polls the
Route53 API until the named record appears, then confirms resolution against
the zone's authoritative nameservers using `dig +norec`, and exits 0 only
when both conditions hold. The script takes either a bare hostname
(`argocd.k8p.example.com`) or an explicit zone ID flag, discovers the hosted
zone automatically from the hostname suffix when the flag is absent, and
prints a timed progress bar so the operator can see which of the two gate
conditions is pending. It is a pure read-only shell script under
`/home/user/k8-platform/scripts/` (one new file, no infrastructure change)
that integrates with the existing `wait_for` pattern used by integration
tests. Part of Tier A, built after Tier S specs; upstream caller for phase 5
(Keycloak ingress) and phase 6 (workload cluster ingresses), both of which
require ExternalDNS reconciliation before the TLS handshake can complete.

## 2. Retro pain killed

- **ExternalDNS IRSA missing `route53:ListHostedZones` — caught only after
  adding pod-log dumps.** `retrospective/2026-05-23-36.md` line 54: "ExternalDNS
  started fine, then every reconcile loop logged `AccessDenied`. Caught only
  after I added pod-log dumps to the failure path in the e2e step." A watch
  loop that polls both the API and an authoritative resolver exposes this class
  of failure in under 30 seconds instead of after a full verify cycle.

- **ExternalDNS install completely missing from helm.tf — DNS never appeared.**
  `retrospective/2026-05-23-36.md` line 52: "The argocd-server ingress
  annotation was reconciled by nothing, so DNS never appeared. The
  longest-living silent bug." `r53-watch.sh` invoked after apply would have
  surfaced "record absent after 120 s" immediately, isolating the missing
  `helm_release` from provider issues or TTL effects.

- **Integration tests 02 and 03 use AWS API polling only — no authoritative
  check.** `tests/integration/02_external_dns_record_creation.sh:54–55` and
  `tests/integration/03_ingress_curl_end_to_end.sh:81–82` both call
  `aws route53 list-resource-record-sets` inside `wait_for` but never verify
  that the record is visible from the zone's authoritative servers. A record
  in the API that has not yet been served by the name-servers has been observed
  to cause curl failures in test 03 ("Even after Route53 has the record, the
  NLB target group may need a minute…") — the comment conflates NLB health and
  DNS visibility.

- **Phase 5 (Keycloak) and phase 6 (workload ingresses) will repeat the same
  pattern.** `ai/brainstorming/specs/larger-list-preferences.md` line 182:
  "ExternalDNS races are the #2 ingress bug. Already a recurring pain point;
  phase 5 (Keycloak ingress) and phase 6 (workload cluster ingresses) will hit
  this repeatedly." Without a shared tool, each phase re-invents a polling
  snippet and makes the same public-recursor mistake.

- **Route53 zone missing — phase 0 fails with a misleading error.**
  `retrospective/2026-05-23-50.md` line 69: "no Route53 zone in the account
  at all" caused a phase 0 failure diagnosed only after an account rotation.
  `r53-watch.sh --preflight` (zone-discovery only, exits 0/1 without polling)
  acts as a lightweight Route53 pre-check ahead of `scripts/aws-creds-check.sh`.

## 3. Out of scope

- **Route53 health checks.** Whether an endpoint is healthy (TCP/HTTP probe
  from Route53's health-checker fleet) is a separate AWS service with
  independent IAM, rate limits, and lifecycle. `r53-watch.sh` confirms DNS
  propagation only. An operator wanting health-check status should use the AWS
  console or `aws route53 get-health-check-status`.

- **DNSSEC validation.** The platform does not configure DNSSEC. Out of scope.

- **Multi-region propagation.** Once Route53's authoritative servers serve the
  record, all edges propagate within seconds. VantagePoint cross-region checks
  are not needed.

- **ExternalDNS diagnostics** (pod logs, IRSA role inspection). That belongs
  to `scripts/diag-component.sh external-dns` (A1-028). This script confirms
  the *result*, not the *cause* of absence.

- **Negative-watch (deletion).** Waiting for a record to disappear is
  symmetric but distinct. This spec covers affirmative propagation only. A
  `--gone` flag is an additive follow-on.

**Considered and rejected:**

- **Extend `scripts/route53-records.sh` with a watch mode.** That script lists
  all zone records for human inspection; fusing it with a blocking watch loop
  conflates two personas. Rejected in favor of a standalone script that is
  non-interactively callable from CI and integration tests.

- **Use `nslookup` or `host` instead of `dig`.** Both send recursive queries
  by default and cannot address a specific authoritative server. `dig @<ns>`
  is the only portable option that bypasses recursors.

- **Poll only the Route53 API.** Tests 02/03 already do that. Without the
  `dig +norec` gate the script adds no value over the existing `wait_for`
  calls.

## 4. Files to change / create

**Create:**

- `/home/user/k8-platform/scripts/r53-watch.sh` — the new script (described
  in §5).

**Modify:**

- `/home/user/k8-platform/scripts/README.md` — add one-line entry for
  `r53-watch.sh` to the scripts table.
- `/home/user/k8-platform/tests/integration/02_external_dns_record_creation.sh`
  — extend the `wait_for` block to call `r53-watch.sh` after the AWS API check
  so the integration test exercises both gates (see §5 for the call pattern).
- `/home/user/k8-platform/tests/integration/03_ingress_curl_end_to_end.sh`
  — same extension as test 02, resolving the misleading "NLB or DNS?" comment.
- `/home/user/k8-platform/AGENTS.md` — §8.1 footnote: "After ExternalDNS
  reconciles an Ingress, use `scripts/r53-watch.sh` to confirm propagation
  before assuming TLS-handshake readiness."

**Create (tests):**

- `/home/user/k8-platform/tests/unit/test_r53_watch.sh` — unit-level tests
  for argument parsing, zone-discovery logic, and `dig` invocation shape (see
  §6).

## 5. Implementation notes

### Authoritative dig vs. public recursors

When a caller runs `dig argocd.k8p.example.com`, the local stub resolver
forwards to a configured public recursor (8.8.8.8, 1.1.1.1, or the VPC
resolver). Public recursors cache aggressively and serve stale `NXDOMAIN` or
old A-records for the full TTL after a Route53 change. Route53 default TTL
for ExternalDNS-created records is 300 s; the VPC resolver in EKS clusters
follows the same cache. That means a public-recursor `dig` can return
`NXDOMAIN` for up to five minutes after the record appears in the Route53 API.

The correct gate is to query Route53's *own* authoritative nameservers
directly:

```bash
# 1. Get authoritative NS for the zone (one-time query via AWS API)
NS_RECORDS=$(aws route53 get-hosted-zone --id "$ZONE_ID" \
  --query 'DelegationSet.NameServers' --output text)

# 2. Pick the first nameserver
AUTH_NS=$(echo "$NS_RECORDS" | awk '{print $1}')

# 3. Query that NS directly, bypassing all recursors
dig +short +norec @"$AUTH_NS" "$HOSTNAME" A CNAME
```

`+norec` (no-recursion-desired bit) tells the server to answer from its own
authoritative data only. If the record is present, `dig` returns the value
and exits 0. If absent, it returns empty and exits 0 (NOERROR with no data);
`grep -q .` on the output distinguishes the two.

For `dig +trace` users: `+trace` forces the resolver to walk the delegation
chain from root → TLD → zone NS, which also bypasses the local cache. It is
useful for manual debugging but produces multi-line output unsuitable for
scripted polling. `+norec @<AUTH_NS>` is the correct programmatic form.

### Script structure

```
r53-watch.sh <hostname> [--zone-id <id>] [--timeout <secs>]
                        [--interval <secs>] [--preflight]
```

Exits: 0 = both gates passed; 1 = timeout; 2 = usage error.

`--preflight`: discover zone only, no polling. Exit 0 if zone found, 1 if not.

Internal flow:

1. Parse args; strip trailing dot from hostname.
2. Zone discovery (when `--zone-id` absent):
   `aws route53 list-hosted-zones --query "HostedZones[?ends_with('.$H.', Name)] | [0].Id"`,
   strip `/hostedzone/` prefix. Fail-fast if no zone.
3. Fetch zone's authoritative NS (one-time):
   `aws route53 get-hosted-zone --id "$ZONE_ID" --query 'DelegationSet.NameServers[0]'`
4. Poll loop (every `$INTERVAL` seconds until `$TIMEOUT`):
   - Gate 1: `aws route53 list-resource-record-sets --hosted-zone-id "$ZONE_ID" --query "ResourceRecordSets[?Name=='${H}.']" --output text | grep -q .`
   - Gate 2 (only after Gate 1 passes): `dig +short +norec @"$AUTH_NS" "$H" | grep -q .`
   - Print to stderr: `[r53-watch] <elapsed>s gate1=<OK|PENDING> gate2=<OK|PENDING> $H`
5. On success: print `-- done` to stdout. On timeout: print failure hints (see below).

Progress lines go to stderr; the single `-- done` line goes to stdout, so
callers can use `&>` to suppress or tee to capture both.

### Integration test call pattern

After the existing `wait_for` block in test 02/03 passes, append:

```bash
bash scripts/r53-watch.sh "$HOST" --zone-id "$ZONE_ID" --timeout 60 --interval 5
ok "ExternalDNS record propagated to authoritative NS for $HOST"
```

60 s is sufficient here: by the time gate 1 passes, the NS edge is almost
always already serving the record. The shorter timeout avoids a slow-test
penalty while still catching the API-ahead-of-NS race.

### No hardcoded account values

Zone ID is discovered dynamically via `aws route53 list-hosted-zones`, per
AGENTS.md §8.1. No account ID, ARN, or DNS suffix appears in the script body.

### Failure output and performance

On timeout, the script emits ≤400 bytes to stderr (within SPEC-A4's ≤5 KB
cap):

```
[r53-watch] TIMEOUT after <N>s: gate1=<state> gate2=<state>
  hint: kubectl logs -n external-dns -l app.kubernetes.io/name=external-dns --tail=50
  hint: scripts/diag-component.sh external-dns
```

Cold path (zone discovery + first poll): ≤3 s. Typical wait: 30–90 s after
ExternalDNS reconciles (default 30 s interval). Default timeout: 300 s,
overridable via `--timeout` or `R53_WATCH_TIMEOUT` env var.

## 6. Tests required

Per AGENTS.md §6.1, these tests are required before the spec is complete.

| Layer | File | Assertion |
|---|---|---|
| Unit | `tests/unit/test_r53_watch.sh` | With `--help` flag, script exits 0 and prints usage. |
| Unit | `tests/unit/test_r53_watch.sh` | With no argument, script exits 2 and prints a usage error on stderr. |
| Unit | `tests/unit/test_r53_watch.sh` | `--timeout` and `--interval` flags are accepted; script does not error before the first poll when AWS env is mocked out (stub `aws` and `dig` that return empty). |
| Unit | `tests/unit/test_r53_watch.sh` | When the stubbed `dig` returns a non-empty line and the stubbed `aws route53 list-resource-record-sets` returns a non-empty result, the script exits 0 on the first iteration (no timeout). |
| Unit | `tests/unit/test_r53_watch.sh` | When the stubs return empty, script exits 1 after one short poll cycle (use `--timeout 1 --interval 1` to bound test runtime to ≤3 s). |
| Integration | `tests/integration/02_external_dns_record_creation.sh` | After extending the test, `bash tests/integration/02_external_dns_record_creation.sh` reports both the API gate and the authoritative gate as OK. Confirm the `r53-watch.sh` invocation appears in the test's output. |

Adversarial review (§6.4): before authoring the unit tests, spawn one subagent
with the §6.4 brief: facts shipped (new script + unit test + two integration
test edits), failure modes (API-ahead-of-NS race, stale recursor cache), and
the explicit non-goal "we are not testing the Route53 API itself".

## 7. Testing suggestions (unit / integration / e2e)

**Unit** — bash/script-level tests in `tests/unit/test_r53_watch.sh`. All
fast (<5 s each) using a `PATH`-overriding stub `aws` and stub `dig` written
inline as shell functions.

1. Zone-discovery logic: stub `aws route53 list-hosted-zones` to return a
   single zone JSON; assert that the script correctly extracts the zone ID and
   strips the `/hostedzone/` prefix before passing it to subsequent calls.
2. Hostname normalization: pass a hostname with a trailing dot
   (`argocd.k8p.example.com.`) and confirm the script strips it before the
   `dig` call (trailing-dot confusion is a common `dig` vs. Route53 mismatch).
3. Gate ordering: confirm gate 1 is checked before gate 2 (stub gate 1 to fail
   and gate 2 to succeed; script must not exit 0).
4. `--preflight` mode: stub returns a zone; script exits 0 with no polling
   loop entered. Also: stub returns no zone; script exits 1.
5. Timeout math: stub both gates to always fail; set `--timeout 3
   --interval 1`; assert script exits 1 within 5 s of wall time.

**Integration** — tests against a live management cluster with a real Route53
zone. Slower (30–120 s depending on ExternalDNS reconcile lag).

1. Run `tests/integration/02_external_dns_record_creation.sh` after the §4
   edit; assert the `r53-watch.sh` call exits 0 and the test overall passes.
2. Create a test Ingress, apply it, invoke `r53-watch.sh --timeout 120`, assert
   exit 0. Exercises the full ExternalDNS → Route53 → NS path.
3. Call `r53-watch.sh` against a hostname absent from the zone with
   `--timeout 5`; assert exit 1 within 10 s (bounds the fail-fast path).
4. `--preflight` against a live account with a zone: assert exit 0. Against an
   account without a zone: assert exit 1.

**E2E** — full-stack scenario against a deployed phase 5 or phase 6 cluster.

1. Phase 5 Keycloak ingress bring-up: invoke `r53-watch.sh keycloak.<domain>`
   as part of the phase-5 verify step before probing the OIDC discovery
   endpoint. Assert exit 0 before the curl-based liveness probe runs. This is
   the canonical production use of the script.
2. Phase 6 workload ingresses: call `r53-watch.sh` for each workload hostname
   in the phase-6 verify script, replacing the inline `wait_for` Route53 poll
   with the authoritative-gate version.
3. Simulated ExternalDNS outage: scale the ExternalDNS Deployment to 0, create
   a new Ingress, invoke `r53-watch.sh --timeout 30`, assert exit 1; scale back
   to 1 and confirm exit 0 on a subsequent call.

If phase 5/6 is not yet deployed when this spec is implemented, skip E2E and
revisit when those phases land. Say so explicitly in the implementing PR.

## 8. Documentation updates

- `/home/user/k8-platform/scripts/README.md` — add `r53-watch.sh` row to the
  scripts table with a one-line description: "Polls Route53 API + authoritative
  NS until a record propagates; exits 0 when both gates pass."
- `/home/user/k8-platform/AGENTS.md` §8.1 — add a footnote: "After
  ExternalDNS reconciles an Ingress, call `scripts/r53-watch.sh <hostname>`
  before assuming TLS-handshake readiness. See SPEC-LA8 for rationale."
- `/home/user/k8-platform/ai/testing-guidelines.md` — add a bullet under the
  integration-test pattern section: "DNS propagation checks must use
  `scripts/r53-watch.sh` (authoritative gate), not a plain `dig` or a
  public-recursor curl loop."
- `/home/user/k8-platform/tests/integration/README.md` — note that tests
  02 and 03 now use `r53-watch.sh` for the DNS gate and reference §5 of this
  spec for the authoritative-vs-recursor distinction.

## 9. Workflow / auto-invocation wiring

`r53-watch.sh` is a **manual runbook script**. It is not wired to any CI
workflow trigger or pre-commit hook — the polling nature (up to 300 s) and
live-AWS dependency make it unsuitable for lint-time or every-push invocation.

Auto-invocation surfaces:

1. **Integration test 02/03** — once §4 modifications land, every run of
   `tests/integration/run.sh` will call `r53-watch.sh` as part of the
   ExternalDNS and ingress tests. This is the primary automated path.
2. **Phase verify runbook** — `ai/handoff.md` will document that the phase 5
   and phase 6 verify steps include `scripts/r53-watch.sh` before TLS probes.
3. **Ad-hoc operator use** — `scripts/README.md` points at it; any operator
   debugging a stale DNS response can invoke it directly.

No `pre-commit` hook is needed. No new workflow file is created.

## 10. Discoverability

1. **Mechanical enforcement** — `tests/unit/test_r53_watch.sh` is run by
   `tests/unit/run.sh` on every push (via `.github/workflows/unit-tests.yml`
   added in PR #47). The test that asserts `r53-watch.sh` accepts `--help` and
   rejects no-argument calls fails CI if the script is accidentally deleted or
   broken. Tests 02 and 03 being edited in §4 will fail integration CI if the
   script disappears.

2. **Documentation pointer** — AGENTS.md §8.1 note (added in §8 of this spec)
   directs any future agent building an Ingress-related phase to `r53-watch.sh`
   before reaching for an ad-hoc polling loop.

3. **Adversarial-review trigger** — add one bullet to the §6.4 adversarial
   checklist in `ai/testing-guidelines.md`: "For any test that polls Route53
   or DNS readiness, confirm it uses `scripts/r53-watch.sh` (authoritative
   gate) rather than a public-recursor `dig` or a plain `aws route53
   list-resource-record-sets` loop."

## 11. Verification checklist

The implementing agent runs these after coding the spec.

- [ ] `bash scripts/r53-watch.sh --help` exits 0 and prints usage text
  containing both `--zone-id` and `--timeout` flags.
- [ ] `bash scripts/r53-watch.sh` (no args) exits 2 and prints a usage
  error to stderr.
- [ ] `bash tests/unit/test_r53_watch.sh` exits 0 with one `PASS` line per
  assertion (at minimum 5 assertions covering the cases in §6).
- [ ] `bash tests/unit/run.sh` exits 0 (new test is discovered and passes
  alongside existing unit tests).
- [ ] In `tests/integration/02_external_dns_record_creation.sh`, grep for
  `r53-watch.sh` returns at least one match:
  `grep -c "r53-watch.sh" tests/integration/02_external_dns_record_creation.sh`
  returns ≥ 1.
- [ ] Same grep for `tests/integration/03_ingress_curl_end_to_end.sh` returns
  ≥ 1.
- [ ] `grep -c "r53-watch.sh" scripts/README.md` returns ≥ 1.
- [ ] `shellcheck scripts/r53-watch.sh` exits 0 (no warnings under `-S
  warning`).
- [ ] Dry-run against a live account with a known hostname:
  `bash scripts/r53-watch.sh argocd.<domain> --timeout 5 --interval 2`
  exits 0 if the record exists, or exits 1 within 10 s if it does not —
  confirming the timeout is honored.
- [ ] `wc -l scripts/r53-watch.sh` is between 80 and 160 lines.

## 12. Rollout notes

- **Backward-compatible.** New file only; no existing behavior changes until
  the §4 integration-test edits land. Those edits append one call after an
  already-passing `wait_for` block — the tests remain green against any cluster
  where the record is genuinely propagated.

- **No Terraform changes, no IAM additions.** The script calls only
  `aws route53 list-hosted-zones`, `get-hosted-zone`, and
  `list-resource-record-sets` — all already granted by the ExternalDNS IRSA
  policy (post PR #34 `route53:ListHostedZones` fix).

- **Pluralsight sandbox constraints** are not relevant — no Terraform or EC2
  resources are touched.

- **Branch sequencing.** Self-contained; no dependency on any in-flight stack.
  Land on `feat/r53-watch` immediately. If phases 5 or 6 are in flight when
  this lands, update their verify steps to call `r53-watch.sh` in the same PR
  as the ingress manifest.

- The integration-test edits are additive. Three-way merge conflicts are
  possible if test 02/03 files are modified on another branch, but the change
  is small enough to resolve quickly.

## 13. Estimated effort

**S** — approximately 1 hour total.

Breakdown: script authoring ~25 min; unit test authoring ~15 min; integration
test edits ~5 min; doc edits ~5 min; §6.4 adversarial-review subagent ~10 min;
§11 verification checklist run ~10 min. Total ≈70 min.

The live-AWS dry-run in §11 requires a cluster to be up. If not available at
implementation time, defer that single item to the next phase-apply cycle
without blocking the PR. All other checklist items are offline.
