# SPEC-LA2 — scripts/eso-trace.sh: ESO chain-walk diagnostic

Brainstorm IDs: A1-028 (core), A4→A1-028 cross-comment (--decode-token extension)
Tier: A (larger-list-preferences.md §A2)

## 1. Summary

Add `scripts/eso-trace.sh <externalsecret> [namespace]`, a read-only bash
script that walks ExternalSecret → ClusterSecretStore → AWS Secrets Manager
ARN → IRSA role trust policy → live `GetSecretValue` (redacted by default).
ESO has six independent failure surfaces; this collapses them into one
structured output block. An optional `--decode-token` flag (brainstorm comment
A4→A1-028) additionally decodes the ESO controller pod's projected SA token,
compares its `sub` claim against the IAM trust policy, and emits a
`MATCH/MISMATCH` token — folding brainstorm idea A1-047 (`oidc-introspect.sh`)
into a single call. The script depends on `scripts/_lib/k8s-helpers.sh` and
`scripts/_lib/aws-cli-helpers.sh`, both created by this spec. The sole
concrete artifacts are the script, two library files, and unit tests; no
cluster-side resources are added or mutated.

## 2. Retro pain killed

- **Five blind chainsaw iterations (PRs #52-#56)** —
  `retrospective/2026-05-24-62.md` line 78: "Without visibility into provider
  state, ESO logs, or composite XR descriptions, every iteration was blind."
  Running `eso-trace.sh` against the stuck ExternalSecret would have emitted
  the CSS auth mode and IRSA role state before PR #52 was opened.

- **IRSA SA-name cascade (PRs #66, #67, #68)** —
  `retrospective/2026-05-25-70.md` line 53: IRSA trust policy bound to
  `upbound-provider-family-aws` while the controller used a hash-suffixed SA.
  The `--decode-token` path emits `IRSA-SUBJECT: MATCH/MISMATCH` in one call
  rather than delegating a 166 KB log to a subagent.

- **ESO webhook cert bug (kind-only, documented-not-fixed)** —
  `retrospective/2026-05-24-62.md` line 112: the STORE section emits
  `ClusterSecretStore.status.conditions[Ready]`, which surfaces TLS-handshake
  failures immediately rather than requiring `kubectl describe` post-hoc.

- **Silent `ResourceNotFoundException` on ASM put** —
  `retrospective/2026-05-24-62.md` line 84: ASM key collision caused by
  UID-shadowing (`k8-platform/1001`). The script's live `GetSecretValue` call
  shows immediately whether the secret exists and is readable, cutting the
  diagnose loop from four failed assertions to one observable call.

- **ESO failure masking as "Secret not found"** — brainstorm A1-052
  justification: "ESO failures are usually IRSA, but masked as 'Secret not
  found'." The chain-walk output attributes the failure to the correct layer
  (missing IAM permission vs wrong ARN vs wrong region vs IRSA mismatch vs
  CSS misconfiguration).

## 3. Out of scope

- **No mutation.** All AWS calls are read-only (`GetSecretValue`, `GetRole`,
  `GetCallerIdentity`); all kubectl calls are `get`/`describe`/`exec`.
- **No CSS cluster-validation (A1-052).** Running AWS CLI from inside the ESO
  pod is a separate deliverable (`eso-cluster-secret-store-validate.sh`).
- **No promotion into CI as an automated test oracle (A2→A1-011).** The
  brainstorm comment proposes this as a follow-on; this spec delivers the
  script in interactive form only.
- **No ExternalSecret auto-remediation.** Diagnosis only.

### Considered and rejected

- **Always-on token decode (not a flag).** Rejected: `kubectl exec` into the
  ESO pod is slow and noisy on healthy clusters. The fast path should be
  pure `kubectl get` + AWS CLI; `--decode-token` is opt-in.
- **JSON output mode.** Rejected for parity with `diag-component.sh` and
  SPEC-A1's chain-block style. Human-readable text is paste-friendly in chat
  escalations. A future `--json` flag can be added independently.
- **Extend `diag-component.sh eso`.** That script dumps namespace-level pod
  state; it has no per-ExternalSecret chain-walk or IAM logic. Adding both
  responsibilities to one file violates the single-responsibility expectation
  visible in the existing per-component case structure.

## 4. Files to change / create

| Path | What changes |
|---|---|
| `/home/user/k8-platform/scripts/eso-trace.sh` | **Create.** Main script (~120 lines). |
| `/home/user/k8-platform/scripts/_lib/k8s-helpers.sh` | **Create.** Shared kubectl helpers (`k8s_get_json`, `k8s_condition`, `require_kube`). |
| `/home/user/k8-platform/scripts/_lib/aws-cli-helpers.sh` | **Create.** Shared AWS helpers (`aws_require_region`, `aws_get_role_trust`, `aws_asm_get_redacted`). |
| `/home/user/k8-platform/tests/unit/test_eso_trace.sh` | **Create.** Unit tests against canned JSON fixtures. |
| `/home/user/k8-platform/tests/unit/fixtures/eso-trace/` | **Create.** Four fixture JSON files: `es-ready.json`, `es-irsa-mismatch.json`, `es-asm-notfound.json`, `iam-trust-wrong-sub.json`. |
| `/home/user/k8-platform/tests/unit/run.sh` | **Modify.** Append `run_suite tests/unit/test_eso_trace.sh`. |
| `/home/user/k8-platform/AGENTS.md` | **Modify.** Add one sentence to §5.1 pointing agents at `eso-trace.sh` before escalating ESO failures. |
| `/home/user/k8-platform/docs/operations.md` | **Modify.** Add 3-line "ESO secret not syncing" stub pointing at the script. |
| `/home/user/k8-platform/scripts/README.md` | **Modify.** Add `eso-trace.sh` to the scripts inventory table. |

## 5. Implementation notes

### 5.1 Invocation

```bash
scripts/eso-trace.sh <externalsecret-name> [namespace] [--decode-token] [--show-value]
```

`namespace` defaults to `default`. `--decode-token` activates the IRSA-subject
comparison path. `--show-value` opts out of redaction — see §5.5.

### 5.2 Section ordering (fail-soft throughout)

Each section is independently fail-soft: if a query errors, print
`<SECTION>: query-failed: <reason>` and continue. Never abort the whole block.

**ES** — `kubectl get externalsecret "$ES_NAME" -n "$NS" -o json`.
Emit kind/name/namespace, `secretStoreRef.name`, `spec.target.name`,
`refreshInterval`. Emit `status.conditions[Ready]` — `Ready=<T|F>`,
`reason`, `message` (≤250 chars via `cut -c1-250`).

**STORE** — `kubectl get clustersecretstore "$STORE_NAME" -o json`.
Emit provider (`aws SecretsManager`), `region`, SA ref (`name/namespace`).
Emit `status.conditions[Ready]`. If not Ready, flag
`STORE: not-Ready — auth failures expected downstream`.

**SA/IRSA** — `kubectl get sa "$SA_NAME" -n "$SA_NS" -o jsonpath='...'`.
Emit the `eks.amazonaws.com/role-arn` annotation value. If absent:
`IRSA: no role-arn annotation — check helm.tf serviceAccount config`.

**IAM** — `aws iam get-role --role-name "$ROLE_NAME"`. Extract the OIDC
`Condition.StringEquals."<oidc-provider>:sub"` from the trust policy.
Emit role ARN and `IAM.trust-subject`.

**ASM** — For each `spec.data[].remoteRef.key` (cap 5):
`aws secretsmanager describe-secret --secret-id "$KEY" --query 'ARN'`.
Emit the ARN or `ASM: not-found — key=<key> region=<region>`.

**FETCH** — `aws secretsmanager get-secret-value --secret-id "$ARN"`.
Redact by default (§5.5). Emit `FETCH: ok (value redacted)` or the AWS
error string on failure.

### 5.3 --decode-token extension (A4→A1-028, folds A1-047)

When `--decode-token` is passed:

1. `kubectl get pod -n external-secrets -l app.kubernetes.io/name=external-secrets -o jsonpath='{.items[0].metadata.name}'`
2. `kubectl exec -n external-secrets "$ESO_POD" -- cat /var/run/secrets/eks.amazonaws.com/serviceaccount/token`
3. Decode the JWT payload with `python3` base64url decode (no external deps).
4. Extract `iss`, `sub`, `aud`.
5. Compare `TOKEN.sub` against `IAM.trust-subject`; emit:

```
TOKEN.sub:         system:serviceaccount:external-secrets:external-secrets
IAM.trust-subject: system:serviceaccount:external-secrets:external-secrets
IRSA-SUBJECT:      MATCH
```

The `MATCH/MISMATCH` token appears exactly once per invocation — this is
the load-bearing signal from the PR #66-#68 cascade (SPEC-A1 §Implementation
notes IRSA section cites the same pattern; the token format is intentionally
consistent so cross-referencing between the two tools is straightforward).

### 5.4 Output format and budget

```
=== ESO TRACE: <es-name> -n <ns> ===
ES       ExternalSecret/<name> -n <ns>
  storeRef: <store-name> (ClusterSecretStore)  target: <k8s-secret>
  status:   Ready=<T|F>  reason=<R>
  message:  <≤250 chars>
STORE    ClusterSecretStore/<store-name>
  provider: aws SecretsManager region=<R>  sa-ref: <name>/<ns>
  status:   Ready=<T|F>
SA/IRSA  <ns>/<sa-name>
  role-arn: <arn>
IAM      <role-name>
  trust-subject: <oidc>:sub = system:serviceaccount:<ns>:<sa>
ASM      (up to 5 data entries)
  [0] key=<key>  ARN=<arn>
FETCH    <arn>
  result:  ok (value redacted)
[DECODE-TOKEN — only with --decode-token]
TOKEN    ESO pod projected token
  iss: <iss>  sub: <sub>  aud: <aud>
  IRSA-SUBJECT: MATCH | MISMATCH
=== END ESO TRACE ===
```

Output budget: ≤4 KB standard path; ≤5 KB with `--decode-token`. ASM entries
capped at 5; `(+N more)` appended if truncated. Messages truncated with
`cut -c1-250` (not `head`).

### 5.5 Redact-by-default policy

`FETCH` calls `secretsmanager:GetSecretValue`. The `SecretString` is
**never printed** unless `--show-value` is passed.

Rationale: the script runs in CI, gets pasted into chat escalations, and
appears in bug reports — all contexts where secret values must not appear.
The diagnostic signal is in the API call's success or failure
(`AccessDeniedException` = IRSA misconfigured; `ResourceNotFoundException`
= wrong ARN/region; clean = credentials work), not in the value itself.

`--show-value` is available for local interactive use only. A unit test
(`test_eso_trace.sh`) asserts that no `.github/workflows/*.yml` or
`tests/chainsaw/**/*.yaml` file contains the literal string `--show-value`.

### 5.6 Pre-flight (per AGENTS.md §8.1)

```bash
aws sts get-caller-identity >/dev/null 2>&1 \
  || { echo "ESO-TRACE: no AWS credentials; IAM/ASM sections skipped"; AWS_SKIP=1; }
REGION="${AWS_REGION:-us-east-1}"
case "$REGION" in
  us-east-1|us-west-2) ;;
  *) echo "ESO-TRACE: region=$REGION outside sandbox allowlist; IAM/ASM skipped"
     AWS_SKIP=1 ;;
esac
```

When `AWS_SKIP=1`, the ES/STORE/SA sections still run (kubectl-only);
IAM/ASM/FETCH emit `skipped` and the script exits 0.

### 5.7 _lib conventions

`scripts/_lib/k8s-helpers.sh`: `k8s_get_json <kind> <name> [-n <ns>]`,
`k8s_condition <json> <type>`, `require_kube` (aborts with a clear message
if kubectl is absent or can't reach a cluster).

`scripts/_lib/aws-cli-helpers.sh`: `aws_require_region` (enforces the
sandbox allowlist), `aws_get_role_trust <role-name>` (wraps `aws iam
get-role`, outputs trust-policy JSON), `aws_asm_get_redacted <secret-id>
<region>` (calls `GetSecretValue`; prints `ok (value redacted)` on success
and the error string on failure; **never** prints the SecretString value).

Performance: ≤8s standard path; ≤12s with `--decode-token`.

## 6. Tests required (per AGENTS.md §6.1)

| Layer | File | Assertion |
|---|---|---|
| Unit | `tests/unit/test_eso_trace.sh` | Fixture `es-ready.json`: output starts `=== ESO TRACE:`, ends `=== END ESO TRACE ===`, contains `Ready=True`, is ≤4096 bytes. |
| Unit | `tests/unit/test_eso_trace.sh` | Fixtures `es-irsa-mismatch.json` + `iam-trust-wrong-sub.json`: output contains `IRSA-SUBJECT: MISMATCH` exactly once. |
| Unit | `tests/unit/test_eso_trace.sh` | Fixture `es-asm-notfound.json`: output contains `ASM: not-found` and does NOT contain the word `SecretString`. |
| Unit | `tests/unit/test_eso_trace.sh` | No `--show-value` flag: output does NOT contain `SecretString` or the fixture's known secret value string. |
| Unit | `tests/unit/test_eso_trace.sh` | Policy guard: `grep -r '\-\-show-value' .github/workflows/ tests/chainsaw/` returns no matches. |
| Unit | `tests/unit/test_eso_trace.sh` | `AWS_SKIP=1` path: IAM/ASM/FETCH sections emit `skipped`; exit code 0. |
| Integration | `tests/integration/13_eso_trace_smoke.sh` | Run against the live ES created by `04_eso_secret_round_trip.sh`. Assert exit 0, `FETCH: ok (value redacted)`, `IRSA-SUBJECT: MATCH`. |

Per AGENTS.md §6.4, before drafting these tests an adversarial subagent review
is required. Brief: (1) new script + two _lib files; (2) the test plan above
with layer + assertion; (3) bug history — five blind chainsaw iterations, IRSA
cascade PRs #66-#68, ESO webhook cert open bug, UID-shadowing ASM collision;
(4) verbatim §6.4 job text; (5) non-goals: no live-cluster unit tests, no AWS
rate-limit testing, no proof of the actual ESO controller's IAM path.

## 7. Testing suggestions (unit / integration / e2e)

Distinct from §6 (gate items); these are the broader catalogue to add as
the surrounding system matures.

### Unit

1. **CSS-not-Ready fixture**: supply CSS with `Ready=False`; assert STORE
   section flags `not-Ready` and downstream sections show `skipped`/degraded
   rather than spurious success.
2. **Multi-data-entry cap**: ES with 7 `spec.data[]` entries; assert output
   contains `(+2 more)` and exactly 5 ASM lines.
3. **Long-message truncation**: fixture whose condition message is 500 chars;
   assert emitted message is ≤250 chars.
4. **`test_k8s_helpers.sh` + `test_aws_cli_helpers.sh`**: one file per _lib,
   verifying helpers against canned inputs via `bash -c` subprocess isolation.
   Verify `require_kube` exits non-zero when kubectl absent; verify
   `aws_asm_get_redacted` never leaks a value string.

### Integration

1. **`13_eso_trace_smoke.sh`** — the §6 required test (already counted above).
2. **`14_eso_trace_irsa_broken.sh`**: temporarily remove the IRSA annotation
   from the `external-secrets` SA, run `eso-trace.sh --decode-token`, assert
   `IRSA-SUBJECT: MISMATCH`, then restore the annotation.
3. **`15_eso_trace_asm_missing.sh`**: point `remoteRef.key` at a known-absent
   ASM secret; assert `ASM: not-found` and exit code 1.

### E2E

1. **`tests/chainsaw/eso-trace-healthy/chainsaw-test.yaml`**: apply a
   PlatformSecret claim, wait for ES Ready, run `eso-trace.sh` as a `script:`
   step, assert `=== END ESO TRACE ===` and `Ready=True`.
2. **`tests/chainsaw/eso-trace-irsa-mismatch/chainsaw-test.yaml`**: claim
   whose CSS SA lacks a valid IRSA annotation; run `eso-trace.sh --decode-token`;
   assert `IRSA-SUBJECT: MISMATCH`. This fixture can be shared with SPEC-A1's
   `chain-walk-irsa-mismatch` scenario (same claim setup).

The E2E layer is the prerequisite for the brainstorm comment A2→A1-011
promotion (making `eso-trace.sh` an oracle inside the ESO chaos test).

## 8. Documentation updates

- **`AGENTS.md` §5.1**: one sentence — "Run `scripts/eso-trace.sh <name>` before
  escalating an ESO failure; the script covers all six known failure modes."
- **`docs/operations.md`**: 3-line "ESO secret not syncing" stub citing the
  script and noting `--decode-token` for IRSA mismatches.
- **`scripts/README.md`**: one-line addition to the scripts table.
- **`ai/testing-guidelines.md`**: note in the ESO/phase-2 section that
  `eso-trace.sh` is the preferred oracle when an ExternalSecret is stuck
  `Ready=False`, and that `--show-value` is banned in committed files.

## 9. Workflow / auto-invocation wiring

This script is a **manual runbook tool**. Two wiring points are recommended
as follow-on work (outside this spec's scope):

1. `diag-component.sh eso` can call `eso-trace.sh` for any ES found in
   `Ready=False` state — a single-line addition once this spec lands.
2. SPEC-A4's `_lib/catch-block.yaml` can add `eso-trace.sh` as a per-resource
   diagnostic call, making it fire automatically on every chainsaw failure
   involving an ExternalSecret.

Until those follow-on wires land, invocation is explicit.

## 10. Discoverability

1. **Mechanical enforcement** — `test_eso_trace.sh` asserts `grep -r
   '--show-value' .github/workflows/ tests/chainsaw/` returns no matches.
   This fires in `unit-tests.yml` on every push, making the redact-by-default
   policy a CI gate. There is nothing else destructive to gate; the script
   is read-only.

2. **Documentation pointer** — `AGENTS.md` §5.1 (updated by this spec) will
   name the script explicitly. Per AGENTS.md §1, AGENTS.md is read at the
   start of every session; the pointer is encountered before any ESO work.

3. **Adversarial-review trigger** — the §6.4 checklist item "Does this test
   plan cover the ESO IRSA mismatch failure mode?" surfaces `eso-trace.sh`
   as the oracle rather than requiring an agent to re-derive the `kubectl
   get sa + aws iam get-role` sequence inline. Once the script exists, that
   checklist item becomes a reference rather than a re-implementation task.

## 11. Verification checklist

- [ ] `bash scripts/eso-trace.sh --help` prints usage with all four flags;
      exits 0.
- [ ] `grep -q test_eso_trace tests/unit/run.sh` — confirms the suite is
      wired into auto-discovery.
- [ ] `bash tests/unit/test_eso_trace.sh` exits 0; output contains
      `=== END ESO TRACE ===`.
- [ ] Against `es-irsa-mismatch.json` + `iam-trust-wrong-sub.json`:
      `grep -c 'IRSA-SUBJECT: MISMATCH' <output>` returns exactly 1.
- [ ] `grep -r '\-\-show-value' .github/workflows/ tests/chainsaw/` returns
      no matches.
- [ ] `source scripts/_lib/aws-cli-helpers.sh; AWS_SKIP=1 aws_asm_get_redacted
      my-secret us-east-1` prints `FETCH: skipped`; does NOT emit `SecretString`.
- [ ] Live cluster: `bash tests/integration/13_eso_trace_smoke.sh` exits 0;
      output contains `FETCH: ok (value redacted)` and `IRSA-SUBJECT: MATCH`.
- [ ] `bash scripts/eso-trace.sh nonexistent-es default` exits non-zero;
      emits `ES: lookup-failed`; no stack trace.
- [ ] `grep 'eso-trace' AGENTS.md` returns a result (pointer wired).
- [ ] Output byte count against `es-ready.json` fixture: ≤4096 bytes.

## 12. Rollout notes

- **Backward-compat**: purely additive. `diag-component.sh`, `04_eso_secret_round_trip.sh`,
  and all existing tests are unchanged by this spec.
- **Audit-before-merge**: the only new CI gate is the `--show-value` absence
  check. No existing committed files contain that flag; no remediation pass
  is needed before this lands green.
- **Sandbox constraints**: all AWS calls stay in `us-east-1` or `us-west-2`
  (enforced by `aws_require_region`). No provisioning; no cost.
- **Coordination**: fully independent of all six clusters in
  `CLUSTERING-REVIEW.md`. Touches no files those clusters modify. Can be
  merged in parallel with any cluster. Soft recommendation: land after
  SPEC-A4 so the §9 chainsaw-catch wiring can reference an already-landed
  catch block.

## 13. Estimated effort

**M** (~2 hours).

- Script authoring (~45 min): ~120 lines of bash; six sequential sections;
  `--decode-token` branch adds ~30 lines; `_lib` files add ~60 lines combined.
- Fixture authoring (~25 min): four hand-trimmed `kubectl get -o json` outputs,
  ~40-60 lines each.
- Unit test authoring (~25 min): six unit cases following the `ok`/`ng`
  pattern from `tests/integration/lib/test-lib.sh`.
- Integration test authoring (~15 min): `13_eso_trace_smoke.sh` mirrors
  `04_eso_secret_round_trip.sh`; ~30 lines net-new.
- Documentation edits (~15 min): three files, ≤5 lines each.
- Adversarial subagent review (~15 min wall-clock, overlaps with fixture
  authoring): dispatch before drafting tests; adopt suggestions.

Rollout audit cost is near-zero: no existing files require remediation.
