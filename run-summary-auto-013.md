# Run Summary — auto-013 (test overhaul: P1 scaffold + substrate + P0-spike read-only)

**Run:** auto-013 · **Date:** 2026-06-07 · **Account:** `695454131301` (fresh) ·
**Authoritative spec:** `planning/test-overhaul/FINAL-PLAN.md` ·
**Envelope:** `planning/test-overhaul/SCOPE-ENVELOPE-auto-013.md` (PR #170)

This is the morning-review artifact (autonomous-run). Read it top-to-bottom; the
PR descriptions are the per-chunk detail.

---

## 1. TL;DR

- **Substrate is LIVE.** phase-0 base + phase-1 **management apply-and-verify
  GREEN** on the fresh account (runs `27085405081`, `27085571769`). EKS
  `k8-platform-mgmt` ACTIVE; ArgoCD + Crossplane + 8 providers + ESO + Kyverno +
  IRSA all up. The auto-012 8-blocker chain did **not** recur.
- **The P0-spike identity spine is CONFIRMED live** (read-only via `kube-diagnose`,
  run `27085946167`): `source: IRSA` exactly; no static-cred AWS ProviderConfig;
  the provider pod runs under SA `upbound-provider-family-aws` with `AWS_ROLE_ARN`
  + `AWS_WEB_IDENTITY_TOKEN_FILE` and **no `AWS_ACCESS_KEY_ID`**; all providers
  `Healthy=True`; all four XRDs `Established=True`, `scope=Namespaced`. The in-band
  identity gate — the only oracle for the unknown-missing-permission class — holds
  on the real cluster.
- **P1 static scaffold shipped as 6 implementation PRs** (#171–#176), each
  cluster-independent and hermetically unit-tested (~67 new assertions), wired
  into `tests/unit/run.sh`.
- **Carried forward:** the v2 `spec.crossplane.resourceRefs` shape on a *live* XR
  (SPIKE-6 — no XR provisioned yet); the "drive a claim ⇒ real AccessDenied" spike
  half; the jentic workflow-integration capstone; P2–P6; standing the
  verifier/reaper role up live.
- **Morning-review items:** 4 (the §14 owner-decisions, all pre-answered in the
  brief — confirm the resolutions). Nothing blocks merging the P1 stack.

## 2. Suggested merge order

Bottom-up; each PR's base is the prior branch (GitHub auto-retargets to `main` as
each merges). All are independently reviewable; **none touch live infra or
workflows at merge time**, so the whole stack is safe to merge in order:

1. **#170** scope envelope (trunk) → `main`
2. **#171** `mgmt_live_verify` gate
3. **#172** coverage deriver
4. **#173** live orchestrator
5. **#174** live-evidence gate
6. **#175** verifier/reaper IAM role (terraform — materializes on the next mgmt apply)
7. **#176** SKIP_REGISTER lint
8. **#177** this summary + retrospective + handoff update

#171–#174 and #176 are pure scripts/tests (zero infra risk). **#175 adds
terraform** (a new IAM role + DynamoDB table) that materializes only on the next
`management apply` — review the policy before that apply.

## 3. PRs opened (stack order)

| PR | Branch | Title | Base | Rewind |
|----|--------|-------|------|--------|
| #170 | `…blissful-faraday-RsPY2` | scope envelope | `main` | revert → pre-run `main` `ef10ce1` |
| #171 | `…p1-compute-gates` | `mgmt_live_verify` derived gate | #170 | revert commit; additive gate only |
| #172 | `…p1-coverage-deriver` | Pipeline-mode coverage deriver | #171 | revert commit; drops `tests/coverage/` |
| #173 | `…p1-live-orchestrator` | inverted-skip live orchestrator | #172 | revert commit; drops `tests/live/` |
| #174 | `…p1-live-evidence-gate` | FAIL-closed live-evidence gate | #173 | revert commit; 2 scripts + test |
| #175 | `…p1-verifier-iam` | scoped verifier/reaper IAM role | #174 | revert commit; no live resource until next apply |
| #176 | `…p1-skip-register-lint` | SKIP_REGISTER lint | #175 | revert commit |
| #177 | `…run-summary` | this summary + retro + handoff | #176 | revert commit (docs only) |

## 4. Decision briefs written

None as standalone two-round briefs: the FINAL-PLAN §14 open questions were
**pre-answered in the run brief**, so they would not have triggered an
`AskUserQuestion`. Their resolutions + rewind paths are in §6. (Per autonomous-run,
a brief with two adversarial rounds is required only when reaching genuine
user-input territory; the owner had already decided all four. Flagged here for
transparency rather than buried.)

## 5. Chain status

- **P1 (visibility + enforcement, static):** the load-bearing mechanisms are built
  and unit-tested — coverage deriver (§4.5), inverted-skip orchestrator (§4.4),
  live-evidence gate (§4.3), scoped verifier identity (§3.4), SKIP_REGISTER lint
  (§4.6), `mgmt_live_verify` (§4.1). **Not yet wired into the live workflow** (the
  capstone is deferred — see §7).
- **P0 spike:** identity spine confirmed live; v2 composed-ref + drive-a-claim
  carried forward.
- **P2–P6:** not started.

## 6. Morning-review items (the §14 owner-decisions — confirm)

1. **Scoped verifier/reaper IAM role (§14.7) — DONE as recommended.** Built in
   #175 (zero-wildcard-action, tag-conditioned, K=0-linted). *Disagree?* revert
   #175. *Open sub-choice:* assume-role trust is account-root + `live-verify`
   session-tag-gated; tighten to a named CI role ARN once it exists.
2. **Spoke public-endpoint CIDR allowlist + CI AccessEntry (§14.2) — CARRIED.**
   Confirm at spike time when phase-3 is provisioned. *Fallback:* CloudTrail-proxy
   + hub-side config (§13).
3. **Tighten `Resource:"*"` on IAM/RDS (§14.3) — CARRIED, recommend tighten.** The
   deny tests ship with the tightening in P4; where risky, kept documented-deferred
   rather than weakening provisioning. *No code change yet.*
4. **ArgoCD controller `role_policy_arns={}` (task #4) — CONFIRMED PRESENT,
   CARRIED.** Verified at `terraform/management/irsa.tf` (`module.irsa_argocd` has
   `role_policy_arns = {}`). Investigate whether spoke registration needs the
   spoke-registration policy attached; add if so. *No code change yet.*

## 7. What I deliberately did NOT do

- **The jentic workflow-integration capstone** — wiring `tests/live/run.sh` into
  `terraform-test.yml`'s apply-and-verify job (gated on `mgmt_live_verify`, under
  the scoped role), emitting the clean-pass evidence artifact, and wiring the
  live-evidence gate + the static wired/gating/scoped/on-by-default lints into a
  push workflow. **Reason:** it edits the live bring-up flow and must be
  dispatch-validated before merge (correction #2 / AGENTS §6.7); landing it
  unvalidated risks breaking the bring-up. All the scripts it wires are built,
  tested, and ready — this is the first task next session.
- **The "drive a claim ⇒ real AccessDenied" spike half** — needs a provisioned
  cheap XR + a crippled-twin grant removal. Read-only spike confirmed identity;
  this is the next spike step.
- **Provisioning phase-3 / the platform cluster** — out of P1 scope; the substrate
  (0→1) proves the mechanism. Phase-3 is needed to confirm SPIKE-6
  (`spec.crossplane.resourceRefs` on a live XR) and the spoke checks.
- **P2–P6** — not started; sequenced behind the spike + capstone.
- **Standing the #175 verifier role up live** — terraform committed, not applied.

## 8. Rewind points

| SHA / PR | Reversal undoes |
|---|---|
| revert PR #170 chain | the entire run → pre-run `main` (`ef10ce1`) |
| from PR #171 onward | keep the envelope, undo all implementation |
| PR #175 only | the verifier/reaper IAM terraform (no live resource yet) |
| (no live rewind needed) | substrate is the normal fresh-account bring-up; nothing destructive |

## 9. Session metadata

- **Branch chain at run end:** `main` → #170 → #171 → #172 → #173 → #174 → #175 →
  #176 → #177.
- **Live runs:** base `27085405081` (✓), management `27085571769` (✓),
  kube-diagnose P0-spike `27085946167` (✓).
- **Subagents:** 0 (§14 decisions were pre-answered; no adversarial briefs
  required). ~67 new hermetic unit assertions across 5 new test files.
- **Self-retrospective:** `retrospective/2026-06-07-177/`.
