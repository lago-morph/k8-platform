# SPEC-A1 — crossplane-claim-verify: chain walk on Ready=False

## Summary

Extend the existing `crossplane-claim-verify` skill so that when a claim
fails to reach `Ready=True` within the Phase-2 timeout, the skill emits a
single, structured **chain block** that walks claim → XR → managed
resources → Provider pod/SA → IRSA trust subject → most-recent AWS API
failure. The block is the agent's primary diagnostic output for the
failure mode that consumed five sequential PRs in the late-2026-05-24
IRSA cascade (PRs #66, #67, #68). Skill semantics on success are
unchanged; the chain walk is purely additive on `Ready=False`.

## Retro pain killed

- **PR #66** — `retrospective/2026-05-25-70.md` Phase 2: subagent
  consumed a 166 KB log to discover the IRSA trust subject
  (`crossplane-system:upbound-provider-family-aws`) did not match the
  hash-suffixed SA Crossplane actually generated
  (`provider-family-aws-24aaab54a3a0`). With this spec the skill would
  emit `IRSA-subject=upbound-provider-family-aws` vs
  `provider-pod-SA=provider-family-aws-24aaab54a3a0` in one block,
  no log extraction required.
- **PR #67** — same retro, Phase 2: post-PR-#66 apply silently no-op'd;
  diagnose round-trip wasted ~10 min before the SA-name was confirmed
  still wrong. A chain block would have shown the SA mismatch was
  unchanged inside one re-run of the skill.
- **PR #68** — same retro, Phase 2: SA existed with the right
  annotation, but the running provider pod was still bound to the
  OLD hash-suffixed SA — only the Deployment-vs-SA mismatch in the
  chain block would have surfaced this without another diagnose dispatch.
- **`retrospective/2026-05-24-62.md` Phase 4** ("claim Waiting" /
  "XR zero conditions"): five chainsaw failures across PR #52/#53 with
  PlatformSecret claims stuck `Ready=False reason=Waiting` and no
  visibility into provider, ESO, or XR state — root cause for
  `dump_diagnostics` in PR #56. A chain block would have emitted the
  XR's empty `.status.conditions` immediately, pointing at the provider
  layer before five iterations of blind chainsaw.

## Out of scope

- No new Kubernetes RBAC, no cluster-side controller, no new MCP tool.
  Skill stays a shell-driven `Bash + Read + Edit + Write` skill.
- No changes to `terraform/`, `crossplane/`, `argocd/`, `clusters/`,
  `platform-services/`, `policies/`, `scripts/`, `.github/`.
- No change to Phase 1-5 happy-path behavior of the skill. Chain walk
  fires only on `Ready=False` after the existing 10-minute Phase 2 cap.
- Does not auto-fix anything new. Diagnosis only; existing Phase 6
  taxonomy handles fixes.
- Does not introduce CloudTrail-as-required — CloudTrail lookup is
  best-effort and falls through cleanly if absent or rate-limited
  (Pluralsight sandbox CloudTrail availability is not guaranteed).
- Does not cover delete-time finalizer chains — that's a separate spec.
- Does not implement the spec; this is design only.

## Files to change / create

| Path | What changes |
|---|---|
| `.claude/skills/crossplane-claim-verify/SKILL.md` | Replace the existing **Phase 6 — On failure** opening with a **Phase 6.0 — Emit chain block** sub-step that runs *before* taxonomy classification; cite the chain-block format from the new reference. Add one paragraph in the front-matter `description` naming "chain walk" and "IRSA subject mismatch" so trigger-matching catches the symptom. |
| `.claude/skills/crossplane-claim-verify/reference/chain-walk.md` | **New.** The canonical chain-block format + the kubectl/aws one-liners that produce each section + the truncation/budget rules (≤5 KB). |
| `.claude/skills/crossplane-claim-verify/reference/failure-taxonomy.md` | Add **one** new row: *symptom* "IRSA subject mismatch: provider pod SA name differs from IRSA trust subject", *category* `irsa-sa-name`, *where to fix* `terraform/management/helm.tf` (DeploymentRuntimeConfig manifest + `triggers_replace` hash — cite PR #66/#67), *Auto?* no — escalate to terraform-ci-watch. |
| `.claude/skills/crossplane-claim-verify/reference/readiness-conditions.md` | Append a 3-line note in **Composites (XRs)** section that **zero conditions** on an XR (after Phase 2 cap) means the Composition pipeline failed before any reconcile — and that the chain block surfaces this as `XR.conditions=<empty>`. |
| `AGENTS.md` §7 | Append one sentence to the `crossplane-claim-verify` bullet: "On `Ready=False` the skill emits a chain block (see skill `reference/chain-walk.md`); paste that block verbatim when escalating." |
| `ai/handoff.md` "Skills inventory" | One-line update noting the chain-walk extension (no behavior change on success). |
| `docs/operations.md` | If a "When a claim won't go Ready" section exists, point it at the chain block; otherwise add a 3-line stub. |

## Implementation notes

The chain walk runs inside the skill at the moment Phase 2's
`kubectl wait` exits non-zero or the 10-minute poll cap is hit with
`Ready=False`. The block is a single fenced text payload printed to
the agent's stdout (the agent then includes it in its user-facing
report and in any escalation per `reference/escalation-template.md`).

### Pre-flight (always)

1. `aws sts get-caller-identity` — per AGENTS §8.1 and
   `ai/aws-test-environment-limitations.md` pre-flight ritual.
2. Confirm region is `us-east-1` or `us-west-2`. If not, abort the
   AWS portion of the chain — print `AWS=skipped: region=<X> outside
   sandbox allowlist`. Do NOT call any other region.

### Section ordering (top → bottom, fail-soft per section)

The agent reads top-to-bottom; sections nearer the top reveal whether
deeper sections are even relevant. Each section is independently
fail-soft: if a query errors, print a single `<section>: <reason>`
line and continue. Never abort the whole block on one missing piece.

1. **CLAIM** — `kind/name -n ns`, `compositionRef`, `.status.conditions[]`
   in the one-liner format already in `readiness-conditions.md`. Use:

   ```
   kubectl get <kind>/<name> -n <ns> -o json | jq -r '...'
   ```

2. **XR** — resolve via `claim.spec.resourceRef.{kind,name}`, then:
   - `.status.conditions[]` (note: may be empty — emit `<empty>` and
     flag as "Composition pipeline error suspected")
   - `.spec.resourceRefs[]` (kind/name per resource)
   - One-line per resourceRef: kind/name, `Synced`, `Ready`, top
     `.status.conditions[0].message` truncated to 200 chars.

3. **MR DETAIL** — for each MR that is `Ready=False` (cap at 5 to stay
   under budget): the `reason` and full `message` of the failing
   condition, plus `.spec.providerConfigRef.name`.

4. **PROVIDER** — derive provider package from the first MR's
   `apiVersion` group (e.g. `s3.aws.upbound.io` → `provider-family-aws`).
   Emit:
   - `kubectl get provider.pkg/<name>` → `Healthy`, `Installed`
   - `kubectl get pod -n crossplane-system -l pkg.crossplane.io/provider=<name>`
     → pod name, phase, restart count
   - **The pod's `spec.serviceAccountName`** (this is the load-bearing
     value that broke PR #66/#68).

5. **IRSA** — for the SA name from step 4:
   - `kubectl get sa <name> -n crossplane-system -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}'`
   - Then `aws iam get-role --role-name <derived-from-arn>` →
     `AssumeRolePolicyDocument` → extract the
     `Condition.StringEquals."<oidc>:sub"` value.
   - Emit both as `IRSA.trust-subject=<sub>` and
     `PROVIDER.pod-SA=system:serviceaccount:crossplane-system:<name>`.
     **Visually diff them** in the block (a literal `MATCH` /
     `MISMATCH` token on its own line) — this is the PR #66 signal.

6. **CLOUD** — best-effort. Try in order, stop at first hit:
   - The **provider pod's recent logs** filtered for `AccessDenied|
     AuthFailure|ValidationException|UnauthorizedOperation`:
     `kubectl logs -n crossplane-system <pod> --tail=200 | grep -E ...`
     (last match wins — newest API failure).
   - If empty, try CloudTrail `LookupEvents` for the IRSA role's last
     `AssumeRoleWithWebIdentity` failure in the last 15 min:
     `aws cloudtrail lookup-events --lookup-attributes
     AttributeKey=EventName,AttributeValue=AssumeRoleWithWebIdentity
     --max-results 5`.
   - If CloudTrail is unavailable or returns nothing, print
     `CLOUD=no recent API failure observed (provider logs empty;
     CloudTrail returned 0)`.

### Output format (verbatim template — keep under ~5 KB)

```
=== CROSSPLANE CHAIN BLOCK ===
CLAIM    <kind>/<name> -n <ns> compRef=<name>
  conditions: Synced=<S> reason=<R> | Ready=<S> reason=<R>
  message:   <single line, ≤200 chars>
XR       <kind>/<name>
  conditions: <as above; "<empty>" if none>
  resourceRefs (<n>):
    - <kind>/<name>  Synced=<S> Ready=<S>  <reason or "<ok>">
    - ... (cap 10; "(+N more)" if truncated)
MR-FAIL  (showing up to 5 Ready=False)
  - <kind>/<name>  reason=<R>
    message: <full, ≤300 chars>
    providerConfigRef: <name>
PROVIDER provider.pkg/<name>  Healthy=<S> Installed=<S>
  pod:    <name>  phase=<P>  restarts=<N>
  pod-SA: system:serviceaccount:crossplane-system:<sa-name>
IRSA     SA-annot role-arn: <arn>
  trust-subject: <oidc-host>:sub = system:serviceaccount:<ns>:<sa>
  MATCH | MISMATCH  ← single token
CLOUD    <one of:
           provider-log: "<verbatim error line>"
           cloudtrail:   <EventName> errorCode=<...> errorMessage=<...>
           no recent API failure observed>
=== END CHAIN BLOCK ===
```

### Partial-data rules

- If the claim can't be located at all → emit only the CLAIM line with
  `lookup-failed`, skip the rest.
- If the XR has no `resourceRefs` yet → skip MR-FAIL and PROVIDER
  derivation; emit `PROVIDER=not-derivable (XR has no resourceRefs)`.
- If multiple providers are in play (rare; phase 4+) → repeat
  PROVIDER + IRSA per distinct providerConfigRef, cap at 3.

### Context economy

The whole block must stay under ~5 KB so it can be pasted into chat
and into the escalation template without consuming the agent's
context. Truncate messages with `cut -c1-N` not `head` (line-aware).
The MR-FAIL cap (5) and resourceRefs cap (10) enforce the upper bound.

## Tests required (per AGENTS.md §6.1)

Three canonical broken-chain fixtures + one happy-path regression test.
Fixtures live alongside the test file in `tests/unit/fixtures/chain-walk/`.

| Layer | File path | Assertion shape |
|---|---|---|
| Unit (shell lint) | `tests/unit/test_chain_walk_format.sh` | Renders the chain-block template against three canned `kubectl get -o json` JSON fixtures (SA-mismatch, missing-MR, provider-unhealthy). Asserts each rendered block (a) starts with `=== CROSSPLANE CHAIN BLOCK ===`, (b) ends with `=== END CHAIN BLOCK ===`, (c) is ≤5120 bytes, (d) contains the literal `MATCH` or `MISMATCH` token exactly once, (e) for the SA-mismatch fixture contains `MISMATCH`, (f) for the missing-MR fixture contains `PROVIDER=not-derivable`, (g) for the provider-unhealthy fixture contains `Healthy=False`. |
| Unit (skill self-test) | `tests/unit/test_skill_chain_walk_doc.sh` | Greps `.claude/skills/crossplane-claim-verify/SKILL.md` for the literal section header `## Phase 6.0 — Emit chain block` and confirms `reference/chain-walk.md` is referenced by relative path. Fails red on the unmodified skill. |
| Unit (taxonomy completeness) | `tests/unit/test_failure_taxonomy_irsa_row.sh` | Greps `reference/failure-taxonomy.md` for a row matching `irsa-sa-name` and citing `PR #66` (or `PR #67`). Defends the new taxonomy row from accidental deletion. |
| Chainsaw | `tests/chainsaw/chain-walk-irsa-mismatch/chainsaw-test.yaml` | Deliberately apply a `PlatformSecret`-shaped claim against a Composition that points at a provider whose SA name doesn't match the IRSA trust subject (use chainsaw's static-cred fixture, mutated to inject the mismatch). Run the skill's chain-walk script as a `script:` step; assert the captured output contains `MISMATCH`. Two more scenarios (`chain-walk-missing-mr/`, `chain-walk-provider-unhealthy/`) cover the other canonical breaks. Each scenario uses `set -eu` per AGENTS §6.6 (no pipefail). |
| Integration | `tests/integration/12_chain_walk_smoke.sh` | Skipped by default; runnable against a live cluster with a known-broken claim. Asserts the skill emits a chain block within 12 min wall-clock and the block contains `=== END CHAIN BLOCK ===`. |

Per AGENTS §6.4, **before** drafting these tests an adversarial subagent
review is mandatory. Brief lists: contracts (format invariants, fail-soft
behavior, ≤5 KB cap, MATCH/MISMATCH exclusivity, partial-data fallbacks,
CloudTrail-absent path, sandbox-region guard), the current plan above,
the known bug history (PRs #66/#67/#68 + the chainsaw "Ready=Waiting"
class from #52/#53), the verbatim job phrasing, and explicit
non-goals (no live-cluster tests in unit layer; no provider-internals
testing; no AWS quota testing).

## Documentation updates

- **`AGENTS.md` §7** — single-sentence addition (see Files table) so any
  agent reading the canonical companion-skills list knows the chain
  block exists and must be pasted in escalations.
- **`.claude/skills/crossplane-claim-verify/SKILL.md`** —
  - Front-matter `description`: add the phrase "On Ready=False emits a
    structured chain block (claim → XR → MRs → Provider → IRSA →
    AWS) — invoke any time a claim is stuck Waiting, Pending, or
    Ready=False past its expected provisioning window."
  - Phase 6 header: insert new **Phase 6.0** sub-step *before* the
    current Classify step. Phase 6.0 says: "Emit the chain block per
    `reference/chain-walk.md`. The block is the diagnostic artifact;
    classify against the taxonomy *using the block*, not the raw
    `kubectl describe` output."
  - Phase 7 (three-strike escalation): require the latest chain block
    be quoted verbatim in the escalation template.
- **`reference/chain-walk.md`** (new): the canonical format + one-liners,
  per the Implementation Notes above.
- **`reference/failure-taxonomy.md`**: new `irsa-sa-name` row.
- **`reference/readiness-conditions.md`**: XR empty-conditions note.
- **`reference/escalation-template.md`** (existing): add a `Chain block`
  placeholder section near the top.
- **`docs/operations.md`**: 3-line "When a claim won't go Ready" stub
  pointing at the skill.

## Workflow / auto-invocation wiring

The skill is **already** auto-invoked per **`AGENTS.md` §7**:

> After applying a Crossplane Claim, XRD, or Composition (whether via
> `kubectl`, ArgoCD sync, or CI), invoke the **`crossplane-claim-verify`**
> skill to wait for `Synced`/`Ready` and verify the underlying cloud
> resource is healthy.

The chain walk extension lives *inside* that existing invocation —
specifically inside Phase 6 of SKILL.md, which is reached whenever
Phase 2's `Ready=True` wait fails. No new trigger is required; the
chain walk fires automatically whenever the skill is triggered AND
the claim doesn't reach Ready=True within Phase 2's 10-minute cap.

Confirmation that the trigger fires: §7's wording covers `kubectl apply`,
ArgoCD sync, AND CI. The three real-world failures (PRs #66/#67/#68)
all happened via the management terraform apply → ArgoCD sync path,
which is in scope.

## Discoverability for future agents

A future agent must be forced to invoke this without remembering it
exists. Forcing functions:

1. **`AGENTS.md` §7** already names the skill by exact name as a
   "testing loop" companion. Agents read `AGENTS.md` per §1.
2. The skill's `description` front-matter (after this spec's edit)
   names the exact symptoms an agent sees ("claim stuck Waiting",
   "Ready=False", "IRSA subject mismatch"). Claude Code's skill
   matcher reads `description` for trigger-phrase matching.
3. **`reference/failure-taxonomy.md`** (after this spec's edit) contains
   the `irsa-sa-name` row — an agent that lands in the taxonomy via
   another path still encounters the chain block in the row's `Fix
   recipe` cell.
4. The skill's Phase 7 escalation template (after edit) requires the
   chain block — meaning if an agent escalates without a chain block,
   it has failed to follow the template, which is easy for the user
   to spot.

## Verification checklist

- [ ] `kubectl apply` a deliberately broken PlatformSecret claim (use
      chainsaw `chain-walk-irsa-mismatch` fixture against a kind
      cluster) — skill emits the chain block within Phase 2's 10-min
      cap, block contains the literal token `MISMATCH`.
- [ ] Skill emits `=== END CHAIN BLOCK ===` (not truncated) on a
      fixture where the XR has 10+ resourceRefs (cap test).
- [ ] Skill emits `CLOUD=no recent API failure observed` when neither
      provider logs nor CloudTrail return a relevant event (fail-soft
      path).
- [ ] On a happy-path claim that reaches `Ready=True`, the skill emits
      its existing Phase 5 success report and **no** chain block
      (proves the chain walk doesn't fire on success).
- [ ] `tests/unit/run.sh` passes including the three new unit tests.
- [ ] Chainsaw scenario `chain-walk-irsa-mismatch` is green in the
      chainsaw workflow (per AGENTS §6.7, manual-dispatched before
      PR open).
- [ ] `aws sts get-caller-identity` is the first command the skill
      runs in any session that requires the AWS portion of the chain.
- [ ] No AWS call in any non-allowlisted region; outside `us-east-1` /
      `us-west-2` the AWS section prints `AWS=skipped` and the rest
      of the block still renders.
- [ ] Skill `description` front-matter contains the trigger phrases
      "Ready=False", "Waiting", and "IRSA" (greppable check).

## Rollout notes

- **Backwards-compat for skill consumers:** the chain block is purely
  additive on the failure path. Existing Phase 1-5 happy-path behavior
  is unchanged; existing Phase 6 taxonomy and Phase 7 escalation are
  extended, not replaced. Any agent that previously invoked the skill
  and inspected its `Synced/Ready` output continues to get exactly that
  output on success.
- **Skill activation triggers:** unchanged — `crossplane-claim-verify`
  still triggers on the same events per `AGENTS.md` §7. Adding the
  new trigger phrases to `description` widens the match surface but
  does not narrow it.
- **Operator surprise risk:** the chain block is verbose (~3-5 KB).
  Agents may want to inline it; users may prefer a link. Default is
  inline (per "evidence-not-exit-codes", `retrospective/2026-05-24-62.md`
  Suggestion 1) — verbatim quoting is the discipline.
- **Sandbox safety:** all AWS calls are read-only (`iam:GetRole`,
  `cloudtrail:LookupEvents`, `sts:GetCallerIdentity`). None mutate; none
  cost meaningfully. Region-guard prevents any out-of-sandbox call.
- **No migration step needed** — the next time the skill is invoked
  on a Ready=False claim, the new behavior kicks in. No state to
  carry forward.

## Estimated effort

**M.** ~150 lines of new skill content (`chain-walk.md`) + ~10 line
edits across SKILL.md / taxonomy / readiness-conditions + ~4 hours
authoring three chainsaw fixtures (each is a small composition +
mutated DeploymentRuntimeConfig) + ~2 hours unit-test authoring with
JSON fixtures. The chainsaw fixtures dominate the effort; the
shell-side chain walk itself is ~80 lines of bash. No Terraform or
provider changes required.
