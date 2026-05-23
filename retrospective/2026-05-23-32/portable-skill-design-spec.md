# Spec: `portable-skill-design`

## Intent

When a skill depends on an environment-specific capability — a CLI's presence, an MCP server's particular tool coverage, a sandbox feature, a network route — the natural failure mode is to write the skill against the current environment and call it done. The skill then works in the environment it was authored in and silently degrades or breaks everywhere else. The fix is to structure environment-dependent skills around a **detection + abstract-operations + per-profile dispatch table + mid-loop degradation** pattern, so the same skill text adapts to whichever profile the host actually presents.

This meta-skill teaches the pattern. It is invoked by an agent that is about to write or rewrite a skill (or a doc) that names a tool/CLI/MCP/sandbox feature as load-bearing — the cue is "this only works if X is present." Instead of hardcoding X, the agent applies the pattern.

Grounded in: PR #32 on `lago-morph/k8-platform`. Commit 1 (`89a9884`) rewrote `terraform-ci-watch` around `ext-github` as the sole path; the user pushed back ("I use a lot of different sandbox types — some have `gh`, some have a richer MCP, some block jentic"); commit 2 (`acbe1eb`) introduced the profile-dispatch design now codified in `.claude/skills/terraform-ci-watch/reference/capabilities.md`. The skill exists to ensure commit 2's structure is reached on commit 1 next time.

## Trigger

**Direct triggers:**

- User says "write a skill for X" where X depends on an environment-specific tool.
- User says "make this portable", "make this work across sandboxes", "what if this environment changes?".
- User says "rewrite this skill to use Y" where Y is a tool that may not exist in every environment.

**Proactive triggers** — apply this pattern without being asked when:

- The skill or doc you're about to write names a CLI (`gh`, `aws`, `kubectl`, `docker`), an MCP server, a sandbox-specific path (`/run/user/...`), or a network route as a load-bearing assumption.
- The user has previously corrected a "this only works here" framing in this session or in a recent retro on the same repo.

**Negative triggers** — do NOT apply when:

- The skill is genuinely single-environment by contract (e.g., a `claude-code-on-the-web-bootstrap` skill that only ever runs in that one host).
- The variability surface is zero (the tool is universal, e.g., `git`).
- The skill is a one-shot script the user explicitly wants tied to their workstation.

## Inputs

- A statement of the skill's purpose (what operation does it drive?).
- A list of the candidate transports for that operation (e.g., `gh`, `github-mcp`, `ext-github`).
- The host environment's current capabilities (which transports are actually available in the session where the skill is being authored).
- The user's preference order between transports — ask if not provided.

## Outputs

Three artifacts per skill:

1. **`SKILL.md`** that references operations abstractly (e.g., "perform LOCATE_RUN") and defers concrete invocation to the dispatch table.
2. **`reference/capabilities.md`** (or equivalent) containing the four required sections (detection, dispatch table, mid-loop degradation, preconditions if any).
3. Optionally, **agents-file updates** that name the profile-detection mechanism rather than naming the current-environment transport directly.

## Workflow

1. **List the abstract operations the skill performs.** For each operation, write down its inputs (parameters), outputs (what it returns), and whether it's a read or a mutating call. Aim for 3–7 operations; if more, the skill is too big.

2. **Enumerate the candidate transports.** At minimum: the most-portable transport (usually a CLI), an MCP-mediated transport if applicable, and a broker-mediated transport (e.g., jentic) as last resort. Ask the user for the preference order if not stated.

3. **Write `capabilities.md` §1 — detection sequence.** Order: check the highest-preference transport first; first hit wins. For each transport, give a concrete check (`command -v X && X auth status`, "look for tool name patterns", "file exists at path P"). Spell out the "what if partial coverage" rule for MCP-style transports — require all required ops to be present, treat partial as not-covered.

4. **Write `capabilities.md` §2 — operation × transport dispatch table.** One row per abstract operation, one column per transport. Each cell is the exact call (CLI command, tool name, file path) for that operation under that transport. Where a transport has a known gap, document the substitute in the cell.

5. **Write `capabilities.md` §3 — mid-loop degradation rule.** What happens when a call fails for a connectivity reason (not an application-level error from the upstream service)? Re-detect once. If detection produces a different transport, retry the operation. If it produces the same transport or no transport, escalate. Forbid ping-pong.

6. **Write `capabilities.md` §4 — preconditions (concurrency, rate limits, auth) that every transport must enforce.** Lift any transport-specific precondition (e.g., "ext-github refuses if >2 queued") to the operation level so it applies regardless of transport.

7. **Write `SKILL.md` against abstract operation names.** Every phase that performs an operation uses the abstract name (e.g., "call LOCATE_RUN") and points at `capabilities.md` §2 for resolution. No transport-specific commands in `SKILL.md` itself.

8. **Cross-file consistency check.** After authoring, `grep` for each operation name and each transport name across `SKILL.md` + `capabilities.md` + any reference docs. Verify that every cross-section reference resolves. Verify that the dispatch-table columns and the detection-sequence transports match.

9. **Update agents-file pointers.** Where the project's `CLAUDE.md` / `AGENTS.md` mentioned the skill, replace any direct mention of a transport with a pointer to the detection mechanism in `capabilities.md`.

## Concrete examples

### Example 1 — `terraform-ci-watch` (the session's own case)

**Skill purpose**: drive `terraform-test.yml` end-to-end via GitHub Actions.

**Abstract operations**: `LOCATE_RUN(workflow_id, branch)`, `POLL_RUN(run_id)`, `LIST_FAILED_JOBS(run_id)`, `FETCH_JOB_LOG(job_id)`, `DISPATCH(workflow_id, ref, inputs)`.

**Transports** (user-stated preference order): `gh` → `github-mcp` → `ext-github`.

**Detection** (Step 3):
- `gh`: `command -v gh >/dev/null && gh auth status >/dev/null 2>&1`.
- `github-mcp`: inspect tool list for `mcp__github__list_workflow_runs`, `mcp__github__get_workflow_run`, etc. Require all five.
- `ext-github`: `.claude/skills/ext-github/SKILL.md` exists, at least one verified recording, jentic execute tool in tool list.

**Dispatch table** (Step 4): see `.claude/skills/terraform-ci-watch/reference/capabilities.md` §2 — five rows × three columns, plus a "Run-wide logs (deliberately not an operation)" note explaining why every transport uses per-job logs uniformly.

**Mid-loop degradation** (Step 5): re-detect on connectivity failure; `ext-github` → "none" escalates to handoff via `ai/handoff.md` per the project's `ai/testing-guidelines.md` §9.

**Concurrency precondition** (Step 6): every transport must check `LIST_RUNS(...)` filtered to `(ref, phase)` before DISPATCH and refuse if `>2` queued. `ext-github` enforces internally; `gh` and `github-mcp` apply the gate around their DISPATCH call.

**`SKILL.md`**: Phase 4 step 5 reads "call DISPATCH(workflow_id, ref, inputs) with the same (phase, action) as the failing run" — no transport-specific command appears.

### Example 2 — hypothetical `aws-bridge` skill

**Skill purpose**: drive AWS CLI operations from a sandbox.

**Abstract operations**: `LIST_RESOURCES(service, region)`, `GET_RESOURCE(arn)`, `CREATE_RESOURCE(spec)`, etc.

**Transports**: `aws` CLI → AWS MCP server → jentic-mediated `ext-aws`.

**Detection**:
- `aws`: `command -v aws >/dev/null && aws sts get-caller-identity >/dev/null 2>&1`.
- AWS MCP: tool list contains `mcp__aws__*` operations covering the required calls.
- `ext-aws`: skill exists with verified recordings; jentic execute tool present.

**Dispatch table** rows include each abstract operation × transport, with cells like `aws s3api list-buckets --region $region` vs `mcp__aws__list_buckets` vs `ext-aws list_buckets` (resource pointer).

**Mid-loop degradation**: identical structure. AWS-specific note: don't demote on `aws sts AccessDenied` — that's application-level, route to error handling, not capability re-detection.

## Anti-patterns

- **Hardcoding the current environment's path in `SKILL.md`.** Commit 1 of PR #32 did exactly this with `ext-github`. If the skill text names a specific transport in a phase, you've baked in the assumption.
- **Skipping the partial-coverage rule for MCP transports.** "MCP has 3 of 5 operations, I'll just call those and fall through to ext-github for the other 2" → brittle: the loop alternates transports mid-call, error handling diverges, debugging gets impossible. Require all-or-nothing per transport.
- **Letting mid-loop degradation ping-pong.** Re-detect ONCE on connectivity failure. If detection picks the same transport, escalate; don't re-try the same transport hoping it self-heals.
- **Treating application-level 4xx/5xx as a capability failure.** A 404 from the upstream service means the resource doesn't exist; it does not mean the transport is broken. Application errors route to the skill's failure taxonomy, not to `capabilities.md` §3.
- **Listing transport-specific concurrency rules inside one transport's profile.** Concurrency is a property of the upstream service, not of the transport. Lift it to the operation level (§4) so all transports enforce it identically.
- **Forgetting the cross-file `grep` check.** Operation names appearing in three files is the recipe for one rename to miss two callsites. Always grep before commit.

## Acceptance criteria

The skill is "done well" when all of these hold:

1. `SKILL.md` contains zero transport-specific commands in the phase descriptions (operations are referenced abstractly).
2. `capabilities.md` §1 (detection) and §2 (dispatch table) list the same set of transports in the same order.
3. `capabilities.md` §2 (dispatch table) and §1 list the same set of abstract operations (no row missing a column, no column missing a row).
4. Cross-file `grep` for each operation name and each transport name shows no typos / no variant spellings.
5. The skill runs end-to-end under at least one transport without code changes when the host environment is altered (i.e., if you remove `gh` from PATH, the skill picks the next available transport and continues).

## Files this skill creates / modifies

- `<skill-dir>/SKILL.md` — the skill's main file; references abstract operations.
- `<skill-dir>/reference/capabilities.md` — detection + dispatch table + degradation + preconditions.
- `<skill-dir>/reference/*.md` (other reference docs) — rewritten around abstract operations when applicable.
- Project agents file (`CLAUDE.md` / `AGENTS.md` at repo root) — replace any direct transport mention with a pointer to the detection mechanism.
