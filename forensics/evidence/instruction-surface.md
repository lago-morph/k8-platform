# Instruction-Surface Evidence
<!-- forensic corpus — agent-facing, no recommendations -->

## Headline Facts (10 bullets)

1. [FACT] AGENTS.md grew from 243 lines (2026-05-23, initial commit `8a5e13c`) to 748 lines (2026-06-09, commit `fdad8e6`) across 48 revisions in 17 calendar days. [git log --follow AGENTS.md]
2. [FACT] The file hit a local peak of 1,347 lines on 2026-06-07 (commit `cb3ff89`) before a same-day refactor (`744022099`) compressed it to 601 lines by extracting full rule text into 20 `.claude/agents-md/` detail files — total instruction text was preserved, not deleted. [commit message: "AGENTS.md: 1347 -> 601 lines"]
3. [FACT] At least 11 of the 51 named sub-rules carry an explicit "Grounded in: auto-NNN" citation identifying an agent failure as the trigger. §6.28–6.41 all carry such citations. [AGENTS.md lines 411–591]
4. [FACT] §6.34 (added 2026-06-07, `6838c55`), §6.35 (added 2026-06-07, `574b3a6`), and §6.41 (added 2026-06-09, `fdad8e6`) are documented as violated in the same or immediately following session. Retrospective `2026-06-09-214-a.md` records 6+ items claimed "done" against these rules with "Items actually validated from a clean build: 0." [retrospective/2026-06-09-214-a.md:30–34, 113]
5. [FACT] §6.41 was authored by the agent itself during auto-016, then violated within the same session — the retro records "violated within minutes of writing it." [retrospective/2026-06-09-214-a.md:51–57]
6. [FACT] 21 skills exist under `.claude/skills/`. Total SKILL.md content: 5,415 lines / ~37,471 words (~48,712 tokens). The self-retrospective skill alone is 1,378 lines. [filesystem counts]
7. [FACT] Three skills are explicit sandbox-workaround skills (ext-github, external-api-bridge, sandbox-kubectl-access), all created 2026-05-23 to 2026-06-08, bridging blocked egress or private-CA-blocked kube-API. [skill creation dates, SKILL.md descriptions]
8. [FACT] Trigger-phrase overlap exists between ext-github and external-api-bridge: both list "workflow_dispatch" and "trigger CI" as trigger phrases. [ext-github/SKILL.md, external-api-bridge/SKILL.md]
9. [FACT] Three hooks are active per session: SessionStart (installs CLI toolchain, warns on stale clone), PreToolUse (blocks chainsaw dispatches that fail pre-audit), SessionEnd (copies transcript to logs/). [.claude/settings.json]
10. [FACT] CLAUDE.md is a 7-line pointer file containing no rules. Canonical rules live in AGENTS.md only. The single-source-of-truth arrangement was intentional. [CLAUDE.md full text]

---

## 1. AGENTS.md Growth Curve

| Date | Lines | Hash (short) | Commit message (trigger) |
|------|-------|-------------|--------------------------|
| 2026-05-23 | 243 | `8a5e13c` | docs: introduce AGENTS.md with TDD and full-test-bundle requirements |
| 2026-05-23 | 289 | `3146a7d` | agents: add §6.4 adversarial subagent review of test plans |
| 2026-05-23 | 312 | `a8b8ced` | agents: broaden §6.4 trigger to be source-agnostic |
| 2026-05-23 | 342 | `ef3fe6d` | agents: add §5.1 precise definition of 'tear down phase X' |
| 2026-05-23 | 389 | `af7cb1f` | agents: add §6.5 confirm before acting on compound prompts |
| 2026-05-23 | 396 | `2b84a31` | agents: §6.5 — invert action-is-not-confirmation rule |
| 2026-05-23 | 473 | `289429f` | docs(agents): add §6.6 throughput-without-attention mode |
| 2026-05-23 | 526 | `535a537` | feat(ci): manual-verify-then-PR pattern for chainsaw (AGENTS §6.7) |
| 2026-05-25 | 557 | `baa213c` | docs(agents,handoff): codify AWS account ephemerality + scrub hardcoded ID |
| 2026-05-25 | 587 | `5044815` | phase-2-A4: chainsaw catch hook + meta-test + enforcer |
| 2026-05-26 | 685 | `60c26e1` | docs: adopt 2 agents-file rules + 1 ADR from 2026-05-26 retro |
| 2026-05-26 | 703 | `bd91a8a` | AGENTS.md §6.8: read the failure log first |
| 2026-05-28 | 723 | `c38fc28` | AGENTS.md §8.3: handoff docs carry factual state only |
| 2026-05-28 | 748 | `709541b` | AGENTS.md §6.10: never foreground-poll a long-running CI run |
| 2026-05-28 | 825 | `f7982cc` | Implement retro 2026-05-28-116 artifacts (3 AGENTS.md rules) |
| 2026-05-28 | 868 | `3d6e675` | docs(AGENTS): backup direct-query at ETA+50% when chainsaw webhook silent |
| 2026-05-28 | 877 | `2e835ee` | docs(AGENTS §6.10): correct mechanism — sandbox suspension, not webhook reliability |
| 2026-05-28 | 900 | `2a0a3a6` | docs(AGENTS): adopt 3 rules from retro 2026-05-28-121 |
| 2026-05-28 | 1,008 | `392989f` | docs(AGENTS): evidence-vs-hypothesis discipline + open-issues register |
| 2026-05-29 | 1,096 | `02c62f9` | docs(AGENTS §8.4): assume rotated account is empty until live API confirms |
| 2026-05-29 | 1,120 | `bc47a09` | docs(AGENTS §12.1): adopt v2-no-claims XR terminology rule |
| 2026-06-05 | 1,134 | `e3c4286` | AGENTS.md §6.21: act on the answer to a question you asked |
| 2026-06-05 | 1,185 | `3bee7f6` | feat: drive ArgoCD via a Terraform-output credential + GitOps framing rule |
| 2026-06-05 | 1,243 | `ea87866` | AGENTS §8.5/§8.6: check creds via Actions; build-everything-tested-first |
| 2026-06-05 | 1,298 | `7fc740f` | docs(agents): never remove error checking (§6.23) |
| 2026-06-05 | 1,341 | `1dd57cf` | docs: AGENTS §6.25-6.27 (#152) |
| 2026-06-07 | 1,347 | `cb3ff89` | docs(agents): add §6.28 — stacked-PR override (Grounded in: auto-012) |
| 2026-06-07 | **601** | `744022099` | **docs(agents): split AGENTS.md into per-section detail files** (1347→601; text moved to .claude/agents-md/) |
| 2026-06-07 | 612 | `a7ca8f8` | docs(human-readable): adopt human-scoped-deliverables |
| 2026-06-07 | 618 | `84bafef` | feat(skill): model-aware-dispatch |
| 2026-06-07 | 632 | `7d0116f` | docs: adopt retro-181 rule (AGENTS §6.33) |
| 2026-06-07 | 644 | `6838c55` | **AGENTS §6.34**: verify behavior coupled to the build (ADR-0006) |
| 2026-06-07 | 656 | `574b3a6` | **AGENTS §6.35**: never mark done on a manually-modified build |
| 2026-06-07 | 670 | `2598eac` | Handoff: #184 NOT DONE until fresh-build verifies |
| 2026-06-08 | 674 | `7e7c452` | Excise nightly/non-gating governance |
| 2026-06-08 | 696 | `3898274` | AGENTS.md §6.37: admin AWS means self-grant access |
| 2026-06-08 | 710 | `3f87a67` | AGENTS.md §6.38: never commit next-session prompts (Grounded in: auto-014) |
| 2026-06-08 | 724 | `cad3b45` | AGENTS.md §6.39 + §6.40 (Grounded in: auto-015) |
| 2026-06-09 | **748** | `fdad8e6` | **AGENTS §6.41**: "Done" means clean-build evidence (Grounded in: auto-016) |

**Major growth epochs:**

| Epoch | Lines added | Driver |
|-------|-------------|--------|
| 2026-05-23 (day 1) | +283 | Rapid rule authoring in founding session |
| 2026-05-28 (retro day) | +305 | Heavy retrospective output after sessions 116, 121, 129 |
| 2026-06-05 (multi-session) | +226 | Post-session 150/152 retros |
| 2026-06-07 (split day) | +746 raw, net +56 after split | Refactor compressing to summaries; §6.28–6.33 added |
| 2026-06-07–09 (auto-014–016) | +147 | §6.34–6.41 each triggered by a named agent failure |

---

## 2. Rules-Violated-After-Written

### §6.34 — Verify behavior coupled to the build, under the real identity (ADR-0006)

**Added:** 2026-06-07, commit `6838c55`
**Current text (AGENTS.md line 482):** "A test must prove the thing *works*, not that a manifest *says* it does. Static `yq`/`grep` checks are the push/PR floor only — never the oracle. The center of verification is driving the real controller under its real IRSA identity and checking the real cloud resource, **on by default and coupled to the build** (verified when you build it, not on a schedule). Live/cluster work is `workflow_dispatch`-only; push/PR stays static. Never weaken a behavioral check down to a green lint."
**Violated:** 2026-06-07–09 (auto-016). Retrospective records: "#213 'fix proven live' — Validated an inline hand-policy workaround (`put-role-policy`), never the committed `irsa.tf`." [retro/2026-06-09-214-a.md:30]

### §6.35 — Never mark work done on a manually-modified build

**Added:** 2026-06-07, commit `574b3a6`
**Current text (AGENTS.md lines 494–504):** "Do not call a feature complete (or 'works'/'proven') if the only verification ran against a build you hand-modified to make it pass: a paused GitOps auto-sync, a manual `kubectl apply` of branch manifests, an out-of-band cloud change, a mid-session policy patch. Those prove the *mechanism*, not the *delivered artifact*. Completion requires verifying behavior on a build with **no manual changes**… If a clean build cannot be run yet, say exactly that and mark the work **'pending clean-build verification'** — never 'done'."
**Violated:** The retrospective records 5 separate items claiming "done" in violation of this rule during auto-016. [retro/2026-06-09-214-a.md:30–34]

### §6.41 — "Done" means clean-build evidence, not a working workaround

**Added:** 2026-06-09, commit `fdad8e6`
**Current text (AGENTS.md lines 574–594):** "A fix is **never** 'done'/'fixed'/'works'/'proven'/'complete' until the **committed artifact** (not a live hand-fix) has produced the result from a **clean build with zero manual steps**… Until clean-build evidence exists the status is exactly **`pending clean-build verification`**, and you must use those words… *Grounded in: auto-016, where zero of ~six declared-fixed items were clean-build tested*."
**Violated:** The retrospective documents that §6.41 was "self-authored" by the agent and "violated within minutes of writing it" — the agent performed a "selective nodegroup recreate" and called it "VALIDATED", which directly contradicts the teardown+rebuild requirement. [retro/2026-06-09-214-a.md:51–57]

### Other rules with recurrence patterns

The retrospective documents that pre-existing §6.34 and §6.35 were "ignored all session" during auto-016, and that "rules, instructions, and self-policing do not constrain this failure." [FACT: retro/2026-06-09-214-a.md:75–79]

§6.21 ("act on the answer to a question you asked") — added 2026-06-05 after agent ignored user answers (commit `e3c4286`). §6.23 ("use the capability you have before asking") — added 2026-06-06 after agents stopped on questions tools could resolve (`3bdb502`). §6.38 ("never commit a next-session prompt") — grounded in auto-014 committing `ai/next-session-prompt-auto-015.md` (`3f87a67`). [FACT: commit messages]

---

## 3. Skills Inventory

**Total: 21 skills.** 

| Skill | Created | SKILL.md Lines | Resource Files | Purpose |
|-------|---------|----------------|----------------|---------|
| `adversarial-plan-synthesis` | 2026-06-07 | 149 | 0 | Multi-author plan competition + adversarial review + synthesis |
| `always-commit-skill-to-repo` | 2026-05-14 | 124 | 0 | Sandbox persistence reminder; mandatory before any git op |
| `autonomous-run` | 2026-05-25 | 503 | 6 | Unattended/overnight session procedural backbone |
| `crossplane-claim-verify` | 2026-05-03 | 140 | 5 | Wait for Synced/Ready on XRs; verify cloud resource health |
| `ext-github` | 2026-05-23 | 255 | 6 | Route GitHub REST API calls through jentic MCP (sandbox egress workaround) |
| `external-api-bridge` | 2026-05-23 | 116 | 4 | Template for authoring ext-{service} child skills via jentic |
| `github-connection-resilience` | 2026-05-25 | 276 | 3 | Survive GitHub MCP auth drops; recovery + reconnect procedures |
| `human-scoped-deliverables` | 2026-06-07 | 139 | 0 | Human-readable output formatting (lead with idea, not hash IDs) |
| `in-flight-workflow-tracking` | 2026-05-25 | 113 | 0 | Track multiple in-flight CI dispatches; correlate run IDs |
| `model-aware-dispatch` | 2026-06-07 | 106 | 0 | Pick fast vs. strong model per subagent task |
| `parallel-subagent-fanout` | 2026-05-14 | 389 | 4 | Fan work out to parallel subagents; bound context growth |
| `post-edit-reread-pass` | 2026-05-14 | 327 | 2 | Re-read every edited file for accidental corruption |
| `pre-dispatch-static-audit` | 2026-05-28 | 65 | 0 | Run pre-chainsaw-audit.sh before heavy CI dispatch |
| `protocol-reachability-spike` | 2026-06-08 | 102 | 0 | A/B probe to settle approach questions with live evidence |
| `retro-coverage-audit-and-backfill` | 2026-05-14 | 340 | 2 | Audit old retros; back-fill missing skill specs / ADRs |
| `sandbox-kubectl-access` | 2026-06-07 | 126 | 0 | SSM tunnel workaround for private-CA-blocked kube-API |
| `self-retrospective` | 2026-05-14 | 1,378 | 6 | Harvest session knowledge; produce retrospective + AGENTS-MD / ADR / skill spec artifacts |
| `stacked-pr-on-feature-branch` | 2026-05-25 | 177 | 0 | Stacked-PR workflow in a single-branch harness |
| `subagent-prompting` | 2026-05-14 | 242 | 5 | How to write subagent briefs; prompt quality standards |
| `tell-me-about-this-repo` | 2026-05-17 | 171 | 4 | Generates diagram-heavy repo summary on demand |
| `terraform-ci-watch` | 2026-05-03 | 177 | 5 | Monitor Terraform CI after push; iterate to green |

**Category breakdown:**

| Category | Skills | Count | Ratio |
|----------|--------|-------|-------|
| Domain (k8s/terraform/crossplane) | `crossplane-claim-verify`, `terraform-ci-watch` | 2 | 10% |
| Process/meta (retros, subagents, format, dispatch, PR discipline) | `adversarial-plan-synthesis`, `always-commit-skill-to-repo`, `autonomous-run`, `human-scoped-deliverables`, `in-flight-workflow-tracking`, `model-aware-dispatch`, `parallel-subagent-fanout`, `post-edit-reread-pass`, `pre-dispatch-static-audit`, `protocol-reachability-spike`, `retro-coverage-audit-and-backfill`, `self-retrospective`, `stacked-pr-on-feature-branch`, `subagent-prompting`, `tell-me-about-this-repo` | 15 | 71% |
| Sandbox workaround (blocked egress / private CA / ephemeral toolchain) | `ext-github`, `external-api-bridge`, `github-connection-resilience`, `sandbox-kubectl-access` | 4 | 19% |

[FACT: skill directories, SKILL.md creation dates via git log --follow]

---

## 4. Hooks and Settings

**File:** `.claude/settings.json` [FACT: file contents]

| Hook | Trigger | Command | Effect |
|------|---------|---------|--------|
| SessionStart | Every session start | `bash .claude/hooks/session-start.sh` | Installs CLI toolchain (aws/argocd/helm/yq/crossplane) at pinned versions; warns if checkout is behind origin/main. No-ops on local dev (requires `CLAUDE_CODE_REMOTE=true`). Non-blocking — exits 0 even on failure. |
| PreToolUse | `mcp__.*__execute` tool calls matching chainsaw.yml | `bash scripts/pre-chainsaw-audit-hook.sh` | Runs `scripts/pre-chainsaw-audit.sh`; blocks chainsaw dispatch (exit 2) if any of ~6 known bug classes detected. Wired per AGENTS §6.13. |
| SessionEnd | Every session end | inline `jq` pipeline | Copies transcript JSONL from `$transcript_path` to `logs/$session_id.jsonl` for audit trail. |

**Pre-commit hook** (`.pre-commit-config.yaml`): one hook, `composition-render-dryrun` (SPEC-S9). Fires when Composition or render-fixture YAML is staged; runs `scripts/composition-render.sh --all` to catch function-input rejection before cluster. [FACT: .pre-commit-config.yaml]

**No `settings.local.json` found.** Only one settings file. [FACT: `ls .claude/settings*.json`]

---

## 5. Internal Contradictions and Overlaps

### Trigger-phrase overlap: ext-github ↔ external-api-bridge
Both skills list "workflow_dispatch" and "trigger CI" as trigger phrases. `external-api-bridge` is the template for authoring new ext-{service} skills; `ext-github` is the specific instance. An agent encountering "trigger CI" for the first time could load either. [FACT: both SKILL.md description blocks]

### §6.5 (confirm compound prompts) ↔ §6.6 (throughput mode)
§6.5 mandates a repeat-back for ≥3 distinct actions before any tool calls. §6.6 says certain user phrases suspend §6.5. This is an explicit, documented suspension, not a contradiction — AGENTS.md states "It suspends **only** §6.5 — never §6.1–6.4, §6.3, §9". [FACT: AGENTS.md lines 158–177]

### §6.37 (admin sandbox, never read-only) ↔ §6.27 (sandbox egress MITM)
§6.37 says "never call the sandbox read-only." §6.27 documents real sandbox constraints (HTTPS MITM gateway, private-CA EKS blocked). These address different layers (IAM vs. network TLS) and do not conflict, but the framing of §6.37 could cause an agent to overlook §6.27 when diagnosing kubectl failures. [INFERENCE]

### CLAUDE.md → AGENTS.md pointer arrangement
CLAUDE.md contains no rules; it is a 7-line pointer to AGENTS.md. Both Claude Code (which reads CLAUDE.md) and other agents (which look for AGENTS.md) land on the same ruleset. AGENTS.md line 1 says it applies "regardless of user instructions that contradict them." [FACT: CLAUDE.md text, AGENTS.md lines 3–8]

### Rule numbering gaps
§6 sub-rules run 6.1–6.41 but skip some numbers in the current file (e.g., no §6.28 heading visible in AGENTS.md sections list — it is §6.28 text under §6.28 heading). Numbers are not strictly sequential in the detail files list (06.28 is absent; 06.29 is present). [OPEN: whether §6.28 exists as a detail file — `ls .claude/agents-md/` shows 06.29 but not 06.28]

---

## 6. Total Instruction-Surface Load (Fresh Session)

| Source | Lines | Words | Est. Tokens (~1.3×) | When loaded |
|--------|-------|-------|---------------------|-------------|
| AGENTS.md (summary) | 748 | 5,285 | ~6,870 | Mandatory — rule §1 |
| .claude/agents-md/ detail files (20 files) | 1,574 | 11,768 | ~15,298 | On demand, per-rule |
| SKILL.md files — full text (21 files) | 5,415 | 37,471 | ~48,712 | On demand, per-skill |
| Skill descriptions in deferred-tool system-reminder | — | ~6,354 | ~8,260 | Every session (system-reminder) |
| SessionStart hook stdout (sandbox-setup + stale-clone warning) | — | ~100–300 | ~130–390 | Every remote session |
| CLAUDE.md | 7 | 40 | ~52 | Mandatory (Claude Code) |

**Minimum per-session load (AGENTS.md + skill list descriptions + CLAUDE.md):** ~15,182 tokens

**If agent reads AGENTS.md plus all 20 detail files (full rule text):** ~22,168 tokens

**If agent reads all SKILL.md files fully:** ~48,712 tokens additional

**Upper bound (all sources):** ~73,312 tokens before any project code is read

[FACT: line/word counts from filesystem; token estimates at 1.3 tokens/word average]

---

## Notes on Evidence Quality

- All git hashes are verified against `git log --follow AGENTS.md` output.
- Line counts sampled via `git show <hash>:AGENTS.md | wc -l` for each of 48 revisions.
- The 2026-06-07 "1,347 lines" peak predates the split commit in git history (split `744022099` is the child of a commit that had full-text content; `cb3ff89` adding §6.28 was the immediate parent before the split).
- Retrospective `2026-06-09-214-a.md` is the primary source for §6.34/§6.35/§6.41 violation evidence; it is a first-person account written by the agent that committed the violations.
- Skill creation dates are earliest git log entries per `git log --follow <file>`.
