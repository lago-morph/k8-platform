# Spec: `gated-branch-endgame`

- **ID**: SKILL-SPEC-e5a4cbc0c3
- **Source retrospective**: ../2026-07-06-255.md

## Intent

Sequence the end of a session whose branch must satisfy exact-HEAD evidence gates (chainsaw-verify, live-evidence-verify) while its documentation must cite run IDs that only exist after dispatch. The skill drives the fixed-point ordering — content-final SHA, dispatch the producer pair, re-run the verifier checks at that SHA, then land run-ID documentation with grep-able placeholders resolved in a follow-up commit that deliberately avoids re-triggering the gates — so a session stops discovering the ordering by trial and re-dispatch. In the 2026-07-06 session (PR #255) this ordering was derived live at the cost of one extra chainsaw dispatch, one extra live-verify dispatch, and a placeholder that leaked into a pushed commit one step early.

## Trigger

- Directly: "finish the branch", "run the endgame", "get the gates green and open the PR", `/gated-branch-endgame`.
- Proactively: the session is about to make its LAST content commit on a branch whose diff touches any path in `chainsaw-verify.yml` or `live-evidence-verify.yml` path filters (`crossplane/**`, `policies/**`, `terraform/management/**`, `tests/live/**`, `tests/chainsaw/**`), AND the session's record-keeping docs (SUBSTRATE-READINESS.md, docs/open-issues.md, ai/handoff.md) will cite run IDs from dispatches that have not happened yet.
- Negative: do NOT trigger for docs-only or test-unit-only branches (no gate matches those paths); do NOT trigger mid-iteration (only when content is believed final).

## Inputs

- The current branch with all CONTENT commits finalized (code, tests, schemas, fixtures — everything except run-ID-bearing docs).
- The set of record-keeping doc edits held in the working tree, with every not-yet-known run ID written as an UPPERCASE grep-able placeholder matching `RUNID-[A-Z-]+`.
- Repo knowledge baked into the skill: the two verifier workflows match by exact `head_sha`; both are `workflow_dispatch`-able and resolve `github.sha` to the branch tip at dispatch time; their PATH FILTERS exclude the record-keeping docs.

## Outputs

- A branch whose final HEAD has: green chainsaw + green live-verify runs recorded at that exact SHA, green chainsaw-verify + live-evidence-verify check runs, and committed docs citing only real, verifiable run IDs.
- A PR whose body lists every run ID (producers and verifiers).

## Workflow

1. Verify content-final: every code/test/schema commit is pushed; `git status --short` shows ONLY the record-keeping docs (if any) modified; `bash scripts/pre-chainsaw-audit.sh` is green. Any doc text drafted ahead of a run's completion carries an UPPERCASE placeholder (`RUNID-[A-Z-]+`), never a guessed number.
2. Dispatch the producer pair at the current HEAD: `chainsaw.yml` (with `commit_sha=<HEAD>` pinned) and `live-verify.yml` (`profile=full`), via the ext-github bridge. One timed background wake-up (~16 min), no polling loops; at ETA+50% silence make one direct status query.
3. On both green: write/resolve the record-keeping docs so every citation is a REAL run ID pasted from a tool result (`sed -i 's/RUNID-<TOKEN>/<id>/'` for drafts; `grep -rn 'RUNID-'` over the three docs must come back empty). Commit the docs, push. This deliberately moves HEAD only after the cited runs exist.
4. Dispatch the producer pair AGAIN at the new final HEAD — the exact-SHA matchers demand evidence at the HEAD they will check. This is a fixed cost of committed run IDs (exactly two rounds, not a loop): the two HEADs differ only by docs, so green is expected; treat a red here as a real regression, not flake.
5. On green: `workflow_dispatch` both verifier gates (`chainsaw-verify.yml`, `live-evidence-verify.yml`) on the branch — their `github.sha` resolves to the final HEAD, where they find the step-4 runs.
6. Create the PR listing: producer runs at both SHAs, verifier runs, and which docs cite which IDs.

## Concrete examples

**Example 1 (the session this spec came from, compressed).** Content HEAD `4b71797` carried the identity feature + live-verify fixes. Producers dispatched there: chainsaw `28759522502` (green), live-verify `28760138628`→ but a relay-check fix intervened (HEAD `085a6f1`), live-verify re-ran green there. Docs committed citing `28760138628` via placeholder resolution → final HEAD `585ff5e`. Producer pair re-dispatched at `585ff5e`: chainsaw `28760632195`, live-verify `28760636850`, both green. Verifiers dispatched: chainsaw-verify `28761129746`, live-evidence-verify `28761131386`, both green. PR #255 opened with all eight IDs; merged clean.

**Example 2 (a hypothetical composition-only fix).** Branch changes `crossplane/compositions/xdatabase.yaml` + its render golden + a SUBSTRATE row note. Step 1: audit green, only SUBSTRATE modified beyond content. Step 3: dispatch chainsaw+live-verify at HEAD `abc1234`; both green (`111`, `222`). Step 4: SUBSTRATE row edited to cite runs 111/222, commit → `def5678`, push. Step 5: re-dispatch pair at `def5678` (`333`, `444`). Step 6: verifier dispatches find 333/444 at `def5678`. Step 7: PR body lists 111/222 (cited in docs) + 333/444 (the gate evidence at final HEAD).

## Anti-patterns

- **Typing a run ID from memory or prediction.** The source session fabricated `28759921550` while drafting ahead of a run's completion; only the placeholder discipline (an UPPERCASE token no reader can mistake for evidence) made the recovery trivial. IDs are pasted from tool results, never composed.
- **Staging docs "for later".** `git commit <explicit-paths>` also commits everything already staged — the source session swept placeholder docs into an unrelated fix commit this way. Stage at commit time only.
- **Polling the dispatched runs in a loop.** One timed background wake-up per wait (the repo's CI-wait discipline); at ETA+50% silence, one direct status query.
- **Pushing new content while a gated dispatch is in flight** (L33) — the run's head_sha is resolved at dispatch; a mid-flight push orphans the evidence.
- **Assuming a docs-only push keeps the old gate evidence valid.** The verifier matchers use exact `head_sha`; they do not know the docs are outside the content. Step 5 exists because of this.

## Acceptance criteria

- `grep -rn 'RUNID-' SUBSTRATE-READINESS.md docs/open-issues.md ai/handoff.md` is empty at the final HEAD.
- Both verifier check runs at the final HEAD conclude success.
- Every run ID appearing in the three record-keeping docs corresponds to a real, conclusion=success workflow run (spot-audit two by clicking).
- Exactly two producer-pair dispatch rounds occurred (no trial-and-error extras).

## Files this skill creates / modifies

- `SUBSTRATE-READINESS.md`, `docs/open-issues.md`, `ai/handoff.md` — placeholder resolution edits only.
- No new files; the skill is pure sequencing over existing workflows (`chainsaw.yml`, `live-verify.yml`, `chainsaw-verify.yml`, `live-evidence-verify.yml`) via the ext-github bridge.
