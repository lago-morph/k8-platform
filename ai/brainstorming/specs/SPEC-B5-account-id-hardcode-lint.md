# SPEC-B5 — `test_no_account_id_hardcoded.sh`: fail on 12-digit AWS account ID literals

## 1. Summary

Add a static-lint unit test that scans tracked files in `ai/`, `terraform/`,
`crossplane/`, `argocd/`, `scripts/`, `tests/`, `.github/`, `docs/`,
`clusters/`, and `platform-services/` for any bare 12-digit decimal literal
matching `\b[0-9]{12}\b` — the shape of an AWS account ID — and fails the
build unless the offending line carries an inline allowlist marker
(`# noqa: account-id - <reason>`). The test makes AGENTS.md §8.1
("the AWS test account is ephemeral — NEVER hardcode account-derived
values") mechanically enforced rather than aspirational, so a rotated
sandbox account never again leaves stale identifiers in tracked docs
or code.

## 2. Retro pain killed

- **AGENTS.md §8.1** (lines 482–512) is the canonical rule. It enumerates
  every artifact class where account-derived values must not appear
  (`ai/handoff.md`, plan/spec/design docs, Terraform `.tf` files, code
  comments, commit messages, PR descriptions, skill content, test
  fixtures, scripts, workflow YAML) and explains why: "When the next
  session reads a stale hardcoded ID, it wastes a debug loop discovering
  'wait, that resource doesn't exist' before realizing the doc lied."
  The rule has existed since the rotation incident but has zero
  mechanical enforcement — every PR relies on reviewer vigilance.
- **Specific prior-session evidence — `ai/handoff.md` line 128:**
  *"AWS account is ephemeral — codified in AGENTS.md §8.1 this session.
  First version of this handoff hardcoded account ID `413117505476` in
  ~12 places (FQDN, S3 bucket name, ACM cert SAN, etc.); user flagged
  that the account is rotated between sessions and stale IDs waste a
  debug loop. Scrubbed and rule added."* That scrub was manual; the
  rule was added without a corresponding test, so the next slip will
  again be caught only by human review or by a subsequent session
  burning time on a stale ID.
- **Recurrence evidence — `ai/handoff.md` line 323:**
  *"Phase 0 brought up from scratch on account `309191981509`…
  `309191981509.realhandsonlabs.net` auto-discovered…"* — a second
  account ID was committed to the handoff after §8.1 was written.
  This is exactly the regression class SPEC-B5 catches.

## 3. Out of scope

- **Git history rewriting.** The test scans the current working tree
  only. Historical commits containing rotated account IDs are not
  rewritten; they are durable audit-trail artifacts (per AGENTS.md §8.1,
  same paragraph that whitelists commit SHAs).
- **AWS access keys** (`AKIA…`/`ASIA…` patterns) — distinct lint, distinct
  spec, distinct severity.
- **Role / resource ARNs at Terraform runtime.** A `data
  "aws_caller_identity" "current"` interpolation that renders an ARN
  *into state at apply time* is fine; the test only checks source files.
- **Terraform `outputs` values produced at apply time.** Those are not
  source.
- **Derived-FQDN literals** (e.g. `309191981509.realhandsonlabs.net`).
  The 12-digit pattern catches the embedded account ID inside such
  FQDNs as a side effect, but the dedicated FQDN check (`\b[0-9]{12}\.realhandsonlabs\.net\b`)
  with separate allowlisting is a deliberate follow-up (SPEC-B5.1 — see §12).
- **Binary files, lockfiles, vendored manifests, `.git/`.** Excluded by
  scope; lockfile hashes contain incidental 12-digit substrings.
- **Generated files under `.terraform/`, `node_modules/`, `vendor/`.**
  Excluded by `.gitignore`; the test only iterates `git ls-files`.

## 4. Files to create

| Path | Purpose |
|------|---------|
| `tests/unit/test_no_account_id_hardcoded.sh` | The lint test itself. Bash, `set -euo pipefail`, follows the conventions of the surrounding `test_*.sh` files (exit 0 = pass, non-zero = fail; emits one offending `file:line:content` per finding). |
| `tests/unit/fixtures/account_id_lint/should_fail_bare_id.txt` | Fixture containing `413117505476` as a bare token — meta-test asserts the lint flags this file when invoked against the fixture dir. |
| `tests/unit/fixtures/account_id_lint/should_fail_in_fqdn.txt` | Fixture containing `309191981509.realhandsonlabs.net` — meta-test asserts the lint flags the embedded 12-digit run (reproduces the handoff.md:323 regression). |
| `tests/unit/fixtures/account_id_lint/should_pass_allowlisted.txt` | Fixture containing `123456789012  # noqa: account-id - documenting the rule itself` — meta-test asserts the lint does NOT flag this. |
| `tests/unit/fixtures/account_id_lint/should_pass_non_id_digits.txt` | Fixture with unix timestamps (10 digits), TCP ports (4–5 digits), SHA-256 prefixes (hex with letters), and a 13-digit millisecond timestamp — meta-test asserts no false positive. |

No new top-level allowlist file is created. Allowlisting is **inline-only**
via the marker comment, by design — a centralized allowlist file invites
copy-paste rot and divorces the exemption from its justification. Inline
markers force the author to state the reason next to the identifier.

## 5. Implementation notes

### Regex

- **Primary pattern:** `\b[0-9]{12}\b` — exactly 12 consecutive decimal
  digits, word-boundary on both sides. Word boundaries reject 13-digit
  ms timestamps, 11-digit phone numbers, and longer hex/digit runs.
- **Search tool:** prefer `git grep -nE` (fast, honors `.gitignore`,
  works on bare checkout in CI). Fall back to `grep -rnE --include`
  only if `git grep` is unavailable.
- **Scope:** the test iterates only the explicit top-level directories
  listed in §1 (`ai`, `terraform`, `crossplane`, `argocd`, `scripts`,
  `tests`, `.github`, `docs`, `clusters`, `platform-services`). Other
  paths (root-level `*.md`, `AGENTS.md` itself) are checked too — they
  are within the spirit of the rule.

### Allowlist marker

- Marker syntax: `# noqa: account-id - <reason>` (Python-style for
  cross-language readability; also accepted: `// noqa: account-id -`,
  `<!-- noqa: account-id - -->`).
- The marker must appear **on the same physical line** as the offending
  literal. Multi-line / file-level allowlists are intentionally not
  supported — they invite drift.
- The lint matches the marker case-insensitively but requires the
  literal substring `noqa: account-id`. A trailing reason is required
  (non-empty after the dash); a marker without a reason is itself a lint
  failure ("allowlist marker present but reason missing on <file>:<line>").

### False-positive handling

- 13+ digit numerics (ms timestamps, nanosecond timestamps) — excluded
  by `\b…\b`.
- ≤11 digit numerics (unix seconds, ports, PIDs) — excluded by length.
- Image SHAs / git SHAs — hex with `a–f` characters, not pure decimal;
  excluded.
- Embedded 12-digit substrings inside longer hex/identifier runs
  (e.g., a 40-char SHA that happens to contain 12 consecutive decimals)
  — excluded by `\b` if the surrounding chars are word-chars; this
  is a known minor blind spot, accepted because the false-negative
  rate is far lower than the false-positive rate of removing `\b`.
- ARNs of the form `arn:aws:iam::123456789012:role/Foo` — the colons
  are non-word, so `\b` triggers; this is **intended** — a bare account
  ID inside an ARN string is exactly what §8.1 forbids.

### Performance

- `git grep -nE '\b[0-9]{12}\b' -- <scoped paths>` on this repo
  (~couple thousand tracked files) is sub-second; no streaming or
  parallelization needed.
- The test must finish in well under 10 s to keep `tests/unit/run.sh`
  snappy. CI-time budget: target <2 s.

## 6. Tests required

Per AGENTS.md §6.1 (meta-tests with fixtures) and §6.2 (TDD):

1. **Meta-test scaffolding inside `test_no_account_id_hardcoded.sh`:**
   the script is invokable in two modes:
   - default — scans the real repo paths and fails on any finding;
   - `--self-test` — runs the regex against `tests/unit/fixtures/account_id_lint/`
     and asserts:
     - `should_fail_bare_id.txt` produces exactly one finding;
     - `should_fail_in_fqdn.txt` produces exactly one finding (reproduces
       the handoff.md:323 prior-session bug);
     - `should_pass_allowlisted.txt` produces zero findings;
     - `should_pass_non_id_digits.txt` produces zero findings;
     - a fixture with a marker missing a reason produces a "reason
       required" failure.
   The self-test runs first; if it fails, the whole script exits
   non-zero before scanning the real repo (a broken regex is more
   important to know about than the scan result).
2. **TDD ordering** (§6.2): write the fixtures first, confirm the
   lint flags them, *then* run against the real repo and clean up
   real findings (see §12 rollout).
3. The fixture for the prior-session regression (item 2 above) is the
   §6.2.5 "bug fix commits with its test" coupling — the fixture text
   should mirror the literal that appeared in the rotated handoff.

## 7. Testing suggestions (unit / integration / e2e)

### Unit

Fast bash/script-level tests under `tests/unit/`. Each runs in under 10 s.

1. `tests/unit/test_no_account_id_hardcoded.sh --self-test` — assert `should_fail_bare_id.txt`
   produces exactly one finding for the bare 12-digit literal `413117505476`.
2. `tests/unit/test_no_account_id_hardcoded.sh --self-test` — assert `should_fail_in_fqdn.txt`
   produces exactly one finding for the embedded ID in `309191981509.realhandsonlabs.net`.
3. `tests/unit/test_no_account_id_hardcoded.sh --self-test` — assert `should_pass_allowlisted.txt`
   produces zero findings when the marker `# noqa: account-id - <reason>` is present.
4. `tests/unit/test_no_account_id_hardcoded.sh --self-test` — assert `should_pass_non_id_digits.txt`
   produces zero findings (unix timestamps, ports, hex SHAs — all non-matching).
5. `tests/unit/test_no_account_id_hardcoded.sh --self-test` — assert a fixture with a
   marker but an empty reason emits a "reason required" failure, not a silent pass.

### Integration

Tests against a live or kind cluster are **not applicable** for this spec. The lint
is a pure static analysis of source files using `git grep`; it has no cluster surface,
no Kubernetes resources, and no AWS API calls. There is nothing to exercise at the
integration layer that is not already covered by the unit self-tests above.

### E2E

Full-stack chainsaw / deployed-cluster probes are **not applicable** for this spec.
The linter runs in CI against the working tree and terminates before any cluster is
involved. An E2E scenario would require a cluster deployment, but the lint gate fires
in the `unit-tests` workflow step — before any cluster-facing workflow step runs.
Conflating the two layers would add infra cost for no coverage gain.

Distinguish from §6: §6 lists the mandatory self-test assertions that gate merging
this spec; §7 catalogues the broader test surface as the surrounding suite matures
(e.g. adding a fuzz fixture with randomised 12-digit strings, or a performance
regression guard that asserts the scan stays under 2 s on a repo of N files).

## 8. Documentation updates

- **`AGENTS.md` §8.1** — add a trailing sentence: *"This rule is
  mechanically enforced by `tests/unit/test_no_account_id_hardcoded.sh`
  (SPEC-B5). Exemptions use the inline marker
  `# noqa: account-id - <reason>`."*
- **`ai/testing-guidelines.md`** — add a row to the unit-test
  inventory describing the lint and pointing at SPEC-B5.
- No new top-level docs. The existing AGENTS.md §8.1 paragraph is the
  durable explanation; the spec file is the design record.

## 9. Workflow / auto-invocation wiring

- **`tests/unit/run.sh`** — append `run_suite tests/unit/test_no_account_id_hardcoded.sh`.
  Keep the file in alphabetical-ish position next to the other shell
  lints (after `test_shell_readonly_var_assignment.sh`).
- **`.github/workflows/unit-tests.yml`** — no edit required; the
  workflow already invokes `tests/unit/run.sh`, so adding a `run_suite`
  line auto-enrolls the new test on every push.
- **Local dev** — `tests/unit/run.sh` from a clean clone runs the
  test; no extra tooling installed beyond `git`, `bash`, `grep`.

## 10. Discoverability for future agents

On failure, the test emits, per finding:

```
FAIL: ai/handoff.md:128: hardcoded 12-digit account-id-shaped literal
      '413117505476'. AGENTS.md §8.1 forbids this. Either remove it
      or add an inline marker:  # noqa: account-id - <reason>
      See: ai/brainstorming/specs/SPEC-B5-account-id-hardcode-lint.md
```

A failing PR check thus shows (a) the exact file and line, (b) the
literal that tripped the lint, (c) the rule citation, (d) the fix
options, (e) the spec for context. No tribal-knowledge step required.

The test's banner (first line of its stdout) also names SPEC-B5 so a
future agent reading CI logs can trace back to this design doc.

## 11. Verification checklist

- [ ] Fixture `should_fail_bare_id.txt` is flagged by `--self-test`.
- [ ] Fixture `should_fail_in_fqdn.txt` is flagged (regression for
      handoff.md:323).
- [ ] Fixture `should_pass_allowlisted.txt` is NOT flagged.
- [ ] Fixture `should_pass_non_id_digits.txt` is NOT flagged
      (timestamps / ports / SHAs).
- [ ] Marker without a reason produces a "reason required" failure.
- [ ] Real-repo scan exits 0 (after rollout audit in §12).
- [ ] `tests/unit/run.sh` invokes the test and surfaces its result.
- [ ] `.github/workflows/unit-tests.yml` runs the suite on push
      (existing behavior; verify run log).
- [ ] AGENTS.md §8.1 trailing sentence links to the test.
- [ ] `ai/testing-guidelines.md` row added.
- [ ] Test completes in <2 s on CI runner.

## 12. Rollout notes

**Audit-before-enforce, in this order:**

1. **Inventory existing hardcodes.** Run
   `git grep -nE '\b[0-9]{12}\b' -- ai/ terraform/ crossplane/ argocd/ scripts/ tests/ .github/ docs/ clusters/ platform-services/ AGENTS.md`
   on the branch BEFORE merging the test. Triage every hit into one
   of three buckets:
   - **Remove** — stale account ID in a doc / plan / handoff. Replace
     with the `<account-id>` placeholder convention AGENTS.md §8.1
     already documents.
   - **Allowlist** — the literal is genuinely talking *about* the rule
     (AGENTS.md §8.1 itself; this spec file's references to
     `413117505476`/`309191981509`/`123456789012`; the retro that
     records the original bug). Inline marker with a one-line reason.
   - **Refactor** — Terraform `.tf` files holding a hardcoded ID must
     migrate to `data.aws_caller_identity.current.account_id` per
     AGENTS.md §8.1 line 493.
2. **Known seeds for the audit** (from grepping during spec authoring):
   - `ai/handoff.md:128` — historical reference to `413117505476`;
     allowlist (it is documenting the bug that motivated §8.1).
   - `ai/handoff.md:323` — historical reference to `309191981509`;
     allowlist (it is a phase-0 narrative; rewrite to `<account-id>`
     if a clean replacement is feasible, otherwise allowlist).
   - `AGENTS.md` §8.1 paragraph — discusses the rule; if the section
     ever cites a literal example ID, allowlist it.
   - This spec file (`SPEC-B5-...md`) — references `413117505476`,
     `309191981509`, `123456789012`; allowlist all of them.
3. **Merge order:** rollout audit fixes ship in the *same PR* as the
   test, so the test is green from its first run. Do NOT land the
   test on a red baseline (it would block every subsequent PR for
   reasons unrelated to that PR's diff).
4. **Pluralsight sandbox constraints** (us-east-1 / us-west-2 only;
   t2/t3/t3a/t4g micro/small/medium; ≤9 EC2; no Bedrock /
   Marketplace) — orthogonal to this spec. The test is a static lint
   and consumes no AWS quota.

## 13. Estimated effort

**S** (small). Roughly:

- 30 min — write the bash test + fixtures.
- 30 min — rollout audit, triage hits, allowlist or scrub.
- 15 min — wire into `run.sh`, update AGENTS.md §8.1 + testing-guidelines.md.
- 15 min — PR review cycle.

Total ≈ 1.5 h elapsed, single session. No AWS spend. No cross-cutting
refactor unless the audit surfaces an unexpectedly large pocket of
hardcoded IDs in `terraform/`, in which case the Terraform migration
splits to a stacked child PR (SPEC-B5.1, also covering the
`*.realhandsonlabs.net` FQDN lint).
